import Darwin
import Foundation

public struct ProbeReceipt: Codable, Equatable, Sendable {
  public let transactionID: UUID
  public let beforeDigest: String
  public let afterDigest: String
  public let unchanged: Bool

  // No-op results are returned to the caller, never persisted as transactions.
  fileprivate func validatePersistedTransaction() throws {
    let digests = [beforeDigest, afterDigest]
    guard !unchanged, beforeDigest != afterDigest,
      digests.allSatisfy({ value in
        value.utf8.count == 64
          && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      })
    else { throw ProbeError.recoveryRequired }
  }
}

public enum ProbeFailurePoint: Sendable {
  case none, beforeBackup, afterBackup, afterJournal, afterReplacement, afterReceipt
}

public enum RecoveryOutcome: Equatable, Sendable {
  case clean, notCommitted, committed, externalChange
}

/// Unprivileged experiment, owning only its newly created private temp directory.
/// This is NOT a production filesystem or privileged transaction implementation.
public actor SandboxSession {
  static let maximumFileBytes = 1_048_576
  private let directory: URL
  private var target: URL { directory.appendingPathComponent("hosts.fixture") }
  private var backup: URL { directory.appendingPathComponent("original.bin") }
  private var journal: URL { directory.appendingPathComponent("journal.json") }
  private var receipt: URL { directory.appendingPathComponent("receipt.json") }

  // The original Apply backup/receipt remain available throughout a Restore.
  private enum TransactionKind: String, Codable {
    case apply, restore

    var backupName: String { self == .apply ? "original.bin" : "restore-before.bin" }
    var receiptName: String { self == .apply ? "receipt.json" : "restore-receipt.json" }
  }

  private struct Journal: Codable {
    let kind: TransactionKind
    let receipt: ProbeReceipt
  }

  public init() throws {
    guard geteuid() != 0 else { throw ProbeError.rootExecutionRefused }
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MacHosts-Probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    do {
      try Data("127.0.0.1 localhost\n::1 localhost\n# foreign comment\r\n".utf8)
        .write(to: directory.appendingPathComponent("hosts.fixture"), options: .withoutOverwriting)
    } catch {
      try FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  public func snapshot() throws -> Data { try readRegular(target) }

  public func apply(
    _ request: ProbeRequest, failure: ProbeFailurePoint = .none
  ) throws -> ProbeReceipt {
    try request.validate()
    guard try !journalExists() else {
      throw ProbeError.recoveryRequired
    }
    let original = try snapshot()
    guard digest(original) == request.expectedDigest else { throw ProbeError.staleRevision }
    let proposed = try ExampleBlock.compose(original, operation: request.operation)
    return try commit(
      original: original, proposed: proposed, transactionID: request.transactionID,
      kind: .apply, failure: failure)
  }

  private func commit(
    original: Data, proposed: Data, transactionID: UUID,
    kind: TransactionKind, failure: ProbeFailurePoint
  ) throws -> ProbeReceipt {
    guard proposed.count <= Self.maximumFileBytes else { throw ProbeError.oversized }
    let result = ProbeReceipt(
      transactionID: transactionID, beforeDigest: digest(original),
      afterDigest: digest(proposed), unchanged: original == proposed)
    if result.unchanged { return result }
    // Reject already unsafe output artifacts before changing even the backup.
    // This preflight does not close the pathname check/replace race below.
    try checkRegular(directory.appendingPathComponent(kind.backupName), allowMissing: true)
    try checkRegular(directory.appendingPathComponent(kind.receiptName), allowMissing: true)
    try failIf(failure == .beforeBackup)
    try writeRegular(original, to: directory.appendingPathComponent(kind.backupName))
    try failIf(failure == .afterBackup)
    try writeRegular(try JSONEncoder().encode(Journal(kind: kind, receipt: result)), to: journal)
    try failIf(failure == .afterJournal)
    guard try snapshot() == original else { throw ProbeError.staleRevision }
    try writeRegular(proposed, to: target)
    try failIf(failure == .afterReplacement)
    guard try snapshot() == proposed else { throw ProbeError.recoveryRequired }
    try writeRegular(
      try JSONEncoder().encode(result), to: directory.appendingPathComponent(kind.receiptName))
    try failIf(failure == .afterReceipt)
    try FileManager.default.removeItem(at: journal)
    return result
  }

  /// Reconstructs outcome without overwriting a subsequently changed file.
  public func recover() throws -> RecoveryOutcome {
    guard try journalExists() else { return .clean }
    let entry = try readRecord(Journal.self, from: journal, journal: true)
    let recorded = entry.receipt
    try recorded.validatePersistedTransaction()
    guard
      digest(try readRegular(directory.appendingPathComponent(entry.kind.backupName)))
        == recorded.beforeDigest
    else {
      throw ProbeError.recoveryRequired
    }
    let current = digest(try snapshot())
    if current == recorded.afterDigest {
      try writeRegular(
        try JSONEncoder().encode(recorded),
        to: directory.appendingPathComponent(entry.kind.receiptName))
      try FileManager.default.removeItem(at: journal)
      return .committed
    }
    if current == recorded.beforeDigest {
      try FileManager.default.removeItem(at: journal)
      return .notCommitted
    }
    return .externalChange
  }

  public func restoreOriginal(
    expectedDigest: String, failure: ProbeFailurePoint = .none
  ) throws {
    guard try !journalExists() else {
      throw ProbeError.recoveryRequired
    }
    let current = try snapshot()
    guard digest(current) == expectedDigest else { throw ProbeError.staleRevision }
    let original = try readRegular(backup)
    let recorded = try readRecord(ProbeReceipt.self, from: receipt)
    try recorded.validatePersistedTransaction()
    guard digest(original) == recorded.beforeDigest else { throw ProbeError.recoveryRequired }
    _ = try commit(
      original: current, proposed: original, transactionID: UUID(), kind: .restore, failure: failure
    )
  }

  public func close() throws { try FileManager.default.removeItem(at: directory) }

  // Internal access for fault injection tests only; never a CLI path parameter.
  func fixtureURL() -> URL { target }

  private func failIf(_ condition: Bool) throws {
    if condition { throw ProbeError.injectedFailure }
  }

  private func readRecord<Record: Decodable>(
    _ type: Record.Type, from url: URL, journal: Bool = false
  ) throws -> Record {
    let bytes = try readRegular(url)
    try TransactionJSON.validate(bytes, journal: journal)
    do {
      return try JSONDecoder().decode(type, from: bytes)
    } catch {
      throw ProbeError.recoveryRequired
    }
  }

  // A dangling journal symlink is an unresolved entry, never a clean session.
  private func journalExists() throws -> Bool {
    var info = stat()
    let result = journal.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return lstat(path, &info)
    }
    if result == 0 { return true }
    guard errno == ENOENT else { throw ProbeError.unsafeFile }
    return false
  }

  private func readRegular(_ url: URL) throws -> Data {
    // Refuse a final-component symlink and avoid blocking while opening a FIFO.
    // Validate the opened object itself, rather than a prior pathname lookup.
    // A file owned by this user may still grant write access to other users.
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw ProbeError.unsafeFile }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    // Always close, including read/limit failures. A close failure also fails the operation.
    let result = Result<Data, any Error> {
      var info = stat()
      guard fstat(descriptor, &info) == 0,
        info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
        info.st_uid == geteuid(), info.st_mode & 0o022 == 0
      else { throw ProbeError.unsafeFile }
      var data = Data()
      while true {
        let remaining = Self.maximumFileBytes + 1 - data.count
        guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty
        else { return data }
        data.append(chunk)
        guard data.count <= Self.maximumFileBytes else { throw ProbeError.oversized }
      }
    }
    try handle.close()
    return try result.get()
  }

  private func writeRegular(_ data: Data, to url: URL) throws {
    try checkRegular(url, allowMissing: true)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  // Writes still have a pathname check/replace gap; NOT a root-safe primitive.
  private func checkRegular(_ url: URL, allowMissing: Bool) throws {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return lstat(path, &info)
    }
    if result != 0 {
      if allowMissing && errno == ENOENT { return }
      throw ProbeError.unsafeFile
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
      info.st_uid == geteuid(), info.st_mode & 0o022 == 0
    else { throw ProbeError.unsafeFile }
  }
}
