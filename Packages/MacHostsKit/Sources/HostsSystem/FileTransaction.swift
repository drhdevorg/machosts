import Foundation
import HostsCore

/// In-process contract only, not a privileged wire format or authorization token.
/// It contains neither a target path nor a complete replacement system file.
struct SystemTransactionRequest: Sendable {
  enum Operation: Sendable {
    case replace(Data)
    case remove
  }
  let version: Int
  let transactionID: UUID
  let expectedDigest: ContentDigest
  let expectedManagedDigest: ContentDigest?
  let resultingDigest: ContentDigest
  let operation: Operation

  init(plan: ApplyPlan) {
    version = 1
    transactionID = plan.id
    expectedDigest = plan.expectedSystemDigest
    expectedManagedDigest = plan.previousManagedDigest
    resultingDigest = plan.resultingSystemDigest
    let document = HostsDocument.parse(plan.after, context: .system)
    if let range = document.managedBlock {
      // Planning preserves the old end-marker terminator. The mutation carries canonical LF;
      // the shared reducer restores that original terminator from the freshly read target.
      let lines = document.lines.filter { range.contains($0.bytes.lowerBound) }
      operation = .replace(Data((lines.map(\.content).joined(separator: "\n") + "\n").utf8))
    } else {
      operation = .remove
    }
  }

  init(
    version: Int = 1, transactionID: UUID = UUID(), expectedDigest: ContentDigest,
    expectedManagedDigest: ContentDigest? = nil, resultingDigest: ContentDigest,
    operation: Operation
  ) {
    self.version = version
    self.transactionID = transactionID
    self.expectedDigest = expectedDigest
    self.expectedManagedDigest = expectedManagedDigest
    self.resultingDigest = resultingDigest
    self.operation = operation
  }

  func revalidate(_ current: Data, evidence: ManagedSeparatorEvidence?) throws
    -> ManagedBlockReplacement
  {
    guard version == 1 else { throw FileTransactionFailure.unsupportedVersion }
    guard ContentDigest(current) == expectedDigest else { throw FileTransactionFailure.staleFile }
    let document = HostsDocument.parse(current, context: .system)
    guard
      document.managedBlock.map({ ContentDigest(current.subdata(in: $0)) })
        == expectedManagedDigest
    else { throw FileTransactionFailure.managedBlockChanged }
    let block: Data
    switch operation {
    case .replace(let data):
      guard !data.isEmpty else { throw FileTransactionFailure.invalidRequest }
      block = data
    case .remove: block = Data()
    }
    let result = try ApplyPlan.replacingManagedBlock(
      in: current, with: block, separatorEvidence: evidence)
    guard ContentDigest(result.data) == resultingDigest else {
      throw FileTransactionFailure.invalidRequest
    }
    return result
  }
}

enum FileTransactionFailure: Error, Equatable {
  case unsupportedVersion, invalidRequest, staleFile, managedBlockChanged
  case recoveryRequired, replay, invalidJournal, backupMismatch, readbackMismatch
}

struct TransactionSnapshot: Codable, Equatable {
  struct Metadata: Codable, Equatable {
    let owner: UInt32
    let group: UInt32
    let mode: UInt16
    let provenance: Data?
  }
  let data: Data
  let device: Int32
  let inode: UInt64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let changeSeconds: Int64
  let changeNanoseconds: Int64
  let metadata: Metadata
}

/// A persisted phase never alone proves that the target still has those bytes.
struct FileTransactionJournal: Codable, Equatable {
  enum Phase: String, Codable { case prepared, committed, notCommitted }
  let version: Int
  let transactionID: UUID
  let backupID: UUID
  let beforeDigest: ContentDigest
  let afterDigest: ContentDigest
  let metadata: TransactionSnapshot.Metadata
  let separatorEvidence: ManagedSeparatorEvidence?
  var phase: Phase
  var receipt: ApplyReceipt?

  func validate() throws {
    guard version == 1, beforeDigest != afterDigest,
      separatorEvidence == nil || separatorEvidence?.systemDigest == afterDigest
    else { throw FileTransactionFailure.invalidJournal }
    if phase == .committed {
      guard let receipt, receipt.transactionID == transactionID, receipt.backupID == backupID,
        receipt.beforeDigest == beforeDigest, receipt.afterDigest == afterDigest,
        receipt.readback == .verified
      else { throw FileTransactionFailure.invalidJournal }
    } else if receipt != nil {
      throw FileTransactionFailure.invalidJournal
    }
  }
}

/// Implementations must hold a process lock for their entire lifetime, use bounded safe reads,
/// persist backups/journals before returning and preserve supported metadata on replacement.
/// Only private test fixtures implement this boundary. No production path adapter exists.
protocol TransactionFiles {
  func readTarget() throws -> TransactionSnapshot
  func synchronizeTarget() throws
  func journals() throws -> [FileTransactionJournal]
  func saveJournal(_ journal: FileTransactionJournal) throws
  func saveBackup(_ original: TransactionSnapshot, id: UUID) throws
  /// Retirements must survive restart and must never be pruned while requests can be replayed.
  func retirements() throws -> [ApplyRetirement]
  func saveRetirement(_ retirement: ApplyRetirement) throws
  /// A prior process may have died between rename and directory sync. Recovery must complete
  /// persistence of the record and its directory before returning terminal exclusion evidence.
  func synchronizeRetirement(_ transactionID: UUID) throws
  func readBackup(_ id: UUID) throws -> TransactionSnapshot
  /// Recheck identity, metadata and bytes immediately before atomic replacement; persist directory.
  func replaceTarget(_ data: Data, expecting original: TransactionSnapshot) throws
}

enum FileTransactionOutcome: Equatable {
  case retired(ApplyRetirement)
  case notCommitted
  case committed(ApplyReceipt)
  case missingJournal
  case unknown
}

/// Synchronous per-lock session. Recovery is explicit and only reconciles evidence; it never
/// restores a full backup or repeats a write. Errors after prepared require reconciliation.
struct FileTransaction {
  let files: any TransactionFiles

  func commit(_ request: SystemTransactionRequest) throws -> ApplyReceipt? {
    let records = try checkedJournals()
    guard
      !(try checkedRetirements(records)).contains(where: {
        $0.transactionID == request.transactionID
      })
    else {
      throw FileTransactionFailure.replay
    }
    guard !records.contains(where: { $0.transactionID == request.transactionID }) else {
      throw FileTransactionFailure.replay
    }
    guard !records.contains(where: { $0.phase == .prepared }) else {
      throw FileTransactionFailure.recoveryRequired
    }
    let original = try files.readTarget()
    // Separator ownership is derived from an independently stored terminal record, never a request.
    let evidence = records.first(where: {
      $0.phase == .committed && $0.afterDigest == ContentDigest(original.data)
    })?.separatorEvidence
    let replacement = try request.revalidate(original.data, evidence: evidence)
    if replacement.data == original.data { return nil }
    try Task.checkCancellation()
    let backupID = UUID()
    try files.saveBackup(original, id: backupID)
    let backup = try files.readBackup(backupID)
    guard backup.data == original.data, backup.metadata == original.metadata else {
      throw FileTransactionFailure.backupMismatch
    }
    var record = FileTransactionJournal(
      version: 1, transactionID: request.transactionID, backupID: backupID,
      beforeDigest: request.expectedDigest, afterDigest: request.resultingDigest,
      metadata: original.metadata, separatorEvidence: replacement.separatorEvidence,
      phase: .prepared)
    try files.saveJournal(record)
    try Task.checkCancellation()
    try files.replaceTarget(replacement.data, expecting: original)
    let actual = try files.readTarget()
    guard actual.data == replacement.data, actual.metadata == original.metadata else {
      throw FileTransactionFailure.readbackMismatch
    }
    let receipt = makeReceipt(record)
    record.phase = .committed
    record.receipt = receipt
    try files.saveJournal(record)
    return receipt
  }

  /// Caller must own the same exclusive session lock, so no earlier worker can still commit.
  func reconcile(_ transactionID: UUID) throws -> FileTransactionOutcome {
    let records = try checkedJournals()
    if let retired = try checkedRetirements(records).first(where: {
      $0.transactionID == transactionID
    }) {
      try files.synchronizeRetirement(retired.transactionID)
      return .retired(retired)
    }
    guard var record = records.first(where: { $0.transactionID == transactionID }) else {
      return .missingJournal
    }
    let current = try files.readTarget()
    guard current.metadata == record.metadata else { return .unknown }
    let digest = ContentDigest(current.data)
    if record.phase == .committed {
      guard digest == record.afterDigest, let receipt = record.receipt else { return .unknown }
      return .committed(receipt)
    }
    if record.phase == .notCommitted {
      return digest == record.beforeDigest ? .notCommitted : .unknown
    }
    if digest == record.beforeDigest {
      record.phase = .notCommitted
      try files.saveJournal(record)
      return .notCommitted
    }
    if digest == record.afterDigest {
      try files.synchronizeTarget()
      guard try files.readTarget() == current else { return .unknown }
      let receipt = makeReceipt(record)
      record.phase = .committed
      record.receipt = receipt
      try files.saveJournal(record)
      return .committed(receipt)
    }
    return .unknown
  }

  /// Explicitly retire a journal-less intent under the same exclusive worker lock as commit.
  /// Matching before-bytes plus a durable fence permit abandoning the app intent, without
  /// asserting that a historical commit never happened. After/foreign bytes remain blocked.
  /// No target write, backup restoration or reconstructed receipt is performed.
  func retireOrphan(_ retirement: ApplyRetirement) throws -> ApplyRetirement {
    try retirement.validate()
    let records = try checkedJournals()
    let retired = try checkedRetirements(records)
    guard
      !records.contains(where: {
        $0.transactionID == retirement.transactionID || $0.phase == .prepared
      })
    else {
      throw FileTransactionFailure.recoveryRequired
    }
    if let existing = retired.first(where: { $0.transactionID == retirement.transactionID }) {
      guard existing == retirement else { throw FileTransactionFailure.invalidJournal }
    }
    let current = try files.readTarget()
    guard ContentDigest(current.data) == retirement.beforeDigest else {
      throw FileTransactionFailure.staleFile
    }
    try Task.checkCancellation()
    if !retired.contains(retirement) { try files.saveRetirement(retirement) }
    // Read the durable record back before permitting app-side resolution. A failed or ambiguous
    // save leaves the intent intact; reconcile can discover a fence on the next restart.
    guard try checkedRetirements(records).contains(retirement) else {
      throw FileTransactionFailure.invalidJournal
    }
    try files.synchronizeRetirement(retirement.transactionID)
    guard try files.readTarget() == current else { throw FileTransactionFailure.staleFile }
    return retirement
  }

  private func checkedRetirements(_ records: [FileTransactionJournal]) throws -> [ApplyRetirement] {
    let retired = try files.retirements()
    guard Set(retired.map(\.transactionID)).count == retired.count,
      Set(retired.map(\.transactionID)).isDisjoint(with: records.map(\.transactionID))
    else { throw FileTransactionFailure.invalidJournal }
    for retirement in retired { try retirement.validate() }
    return retired
  }

  private func checkedJournals() throws -> [FileTransactionJournal] {
    let records = try files.journals()
    guard Set(records.map(\.transactionID)).count == records.count,
      records.filter({ $0.phase == .prepared }).count <= 1
    else { throw FileTransactionFailure.invalidJournal }
    for record in records {
      try record.validate()
      let backup = try files.readBackup(record.backupID)
      guard ContentDigest(backup.data) == record.beforeDigest, backup.metadata == record.metadata
      else {
        throw FileTransactionFailure.backupMismatch
      }
    }
    return records
  }

  private func makeReceipt(_ record: FileTransactionJournal) -> ApplyReceipt {
    ApplyReceipt(
      transactionID: record.transactionID, beforeDigest: record.beforeDigest,
      afterDigest: record.afterDigest, backupID: record.backupID,
      readback: .verified, cacheFlush: .notAttempted)
  }
}
