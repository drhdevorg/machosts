import Darwin
import Foundation
import HostsCore
import Testing

@testable import HostsSystem

private func plan(_ original: Data, source: String = "203.0.113.4 staging") throws -> ApplyPlan {
  try ApplyPlan.prepare(
    workspace: Workspace(profiles: [Profile(name: "Test", source: source, isEnabled: true)]),
    system: original)
}

@Test func fixtureCommitBackupReadbackReplayAndDisable() throws {
  let original = Data("# foreign without terminator".utf8)
  let files = try PrivateTransactionFiles(original)
  try files.verifySecondLockIsRejected()
  let transaction = FileTransaction(files: files)
  let prepared = try plan(original)
  let receipt = try #require(try transaction.commit(SystemTransactionRequest(plan: prepared)))
  #expect(receipt.afterDigest == prepared.resultingSystemDigest)
  #expect(receipt.cacheFlush == .notAttempted)
  #expect(try files.readTarget().data == prepared.after)
  #expect(try files.readBackup(receipt.backupID).data == original)
  #expect(try transaction.reconcile(prepared.id) == .committed(receipt))
  #expect(throws: FileTransactionFailure.replay) {
    try transaction.commit(SystemTransactionRequest(plan: prepared))
  }
  let unchanged = try plan(prepared.after)
  #expect(try transaction.commit(SystemTransactionRequest(plan: unchanged)) == nil)
  #expect(try files.journals().count == 1)
  let disabled = try ApplyPlan.prepare(
    workspace: Workspace(), system: prepared.after, separatorEvidence: prepared.separatorEvidence)
  _ = try #require(try transaction.commit(SystemTransactionRequest(plan: disabled)))
  #expect(try files.readTarget().data == original)
  #expect(try files.journals().count == 2)
}

@Test(arguments: TransactionFault.allCases)
func interruptionReconcilesActualFixtureBytes(_ fault: TransactionFault) throws {
  let original = Data("127.0.0.1 localhost\r\n# foreign\r\n".utf8)
  let files = try PrivateTransactionFiles(original)
  let prepared = try plan(original)
  let request = SystemTransactionRequest(plan: prepared)
  files.fault = fault
  #expect(throws: FixtureFailure.injected) { try FileTransaction(files: files).commit(request) }
  let committed = [.afterRename, .readback, .receipt].contains(fault)
  #expect(try files.readTarget().data == (committed ? prepared.after : original))
  let hasJournal = ![.backup, .prepared].contains(fault)
  if hasJournal {
    #expect(throws: FileTransactionFailure.replay) {
      try FileTransaction(files: files).commit(request)
    }
    let next = try plan(try files.readTarget().data, source: "203.0.113.5 staging")
    #expect(throws: FileTransactionFailure.recoveryRequired) {
      try FileTransaction(files: files).commit(SystemTransactionRequest(plan: next))
    }
  }
  let restarted = files.restartSession()
  let outcome = try restarted.reconcile(prepared.id)
  if committed {
    guard case .committed(let receipt) = outcome else {
      Issue.record("After-bytes and durable journal should reconstruct a receipt")
      return
    }
    #expect(receipt.transactionID == prepared.id)
    #expect(receipt.afterDigest == prepared.resultingSystemDigest)
    #expect(try files.journals().first?.receipt == receipt)
  } else {
    #expect(outcome == (hasJournal ? .notCommitted : .missingJournal))
  }
  #expect(try files.readTarget().data == (committed ? prepared.after : original))
}

@Test func externalMutationBeforeRenameAndDuringRecoveryIsPreserved() throws {
  let original = Data("# original\n".utf8)
  let external = Data("# external\n192.0.2.3 vpn\n".utf8)
  let files = try PrivateTransactionFiles(original)
  let prepared = try plan(original)
  files.beforeRename = { try files.mutateTarget(external) }
  #expect(throws: FileTransactionFailure.staleFile) {
    try FileTransaction(files: files).commit(SystemTransactionRequest(plan: prepared))
  }
  let restarted = files.restartSession()
  #expect(try restarted.reconcile(prepared.id) == .unknown)
  #expect(try files.readTarget().data == external)
  #expect(try files.journals().first?.phase == .prepared)
}

@Test func sameBytesWithDifferentIdentityRejectsRename() throws {
  let original = Data("# original\n".utf8)
  let files = try PrivateTransactionFiles(original)
  let prepared = try plan(original)
  files.beforeRename = { try files.mutateTarget(original) }
  #expect(throws: FileTransactionFailure.staleFile) {
    try FileTransaction(files: files).commit(SystemTransactionRequest(plan: prepared))
  }
  #expect(try files.restartSession().reconcile(prepared.id) == .notCommitted)
  #expect(try files.readTarget().data == original)
}

@Test func invalidRequestsCannotPublishBackupOrJournal() throws {
  let original = Data("# foreign\n".utf8)
  let files = try PrivateTransactionFiles(original)
  let prepared = try plan(original)
  let badBlocks = [
    Data(), Data("192.0.2.1 arbitrary\n".utf8),
    Data(("# injected prefix\n" + String(decoding: prepared.after, as: UTF8.self)).utf8),
    Data(
      (HostsSyntax.begin + "\n# machosts-disabled: 192.0.2.1 staging\n" + HostsSyntax.end + "\n")
        .utf8),
    Data((HostsSyntax.begin + "\ninvalid staging\n" + HostsSyntax.end + "\n").utf8),
    Data(repeating: 65, count: HostsLimits.systemBytes + 1),
  ]
  for block in badBlocks {
    let request = SystemTransactionRequest(
      expectedDigest: ContentDigest(original), resultingDigest: ContentDigest(block),
      operation: .replace(block))
    #expect(throws: (any Error).self) { try FileTransaction(files: files).commit(request) }
  }
  let unsupported = SystemTransactionRequest(
    version: 99, expectedDigest: ContentDigest(original), resultingDigest: ContentDigest(Data()),
    operation: .remove)
  #expect(throws: FileTransactionFailure.unsupportedVersion) {
    try FileTransaction(files: files).commit(unsupported)
  }
  let stale = try plan(Data("# other\n".utf8))
  #expect(throws: FileTransactionFailure.staleFile) {
    try FileTransaction(files: files).commit(SystemTransactionRequest(plan: stale))
  }
  #expect(try files.journals().isEmpty)
  #expect(try files.readTarget().data == original)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: files.directory.path).sorted()
      == [".lock", "target"])
}

@Test func fileBoundaryRechecksConflictsAndManagedOwnership() throws {
  let original = Data("192.0.2.1 staging\n".utf8)
  let files = try PrivateTransactionFiles(original)
  let block = Data((HostsSyntax.begin + "\n203.0.113.2 staging\n" + HostsSyntax.end + "\n").utf8)
  let request = SystemTransactionRequest(
    expectedDigest: ContentDigest(original), resultingDigest: ContentDigest(original + block),
    operation: .replace(block))
  #expect(throws: (any Error).self) { try FileTransaction(files: files).commit(request) }
  let existing = try plan(Data()).after
  let ownedFiles = try PrivateTransactionFiles(existing)
  let removal = SystemTransactionRequest(
    expectedDigest: ContentDigest(existing), resultingDigest: ContentDigest(Data()),
    operation: .remove)
  #expect(throws: FileTransactionFailure.managedBlockChanged) {
    try FileTransaction(files: ownedFiles).commit(removal)
  }
  #expect(try ownedFiles.readTarget().data == existing)
}

@Test func corruptedBackupBlocksReconciliationAndNewWrites() throws {
  let files = try PrivateTransactionFiles(Data("# original\n".utf8))
  let prepared = try plan(try files.readTarget().data)
  files.fault = .afterRename
  #expect(throws: FixtureFailure.injected) {
    try FileTransaction(files: files).commit(SystemTransactionRequest(plan: prepared))
  }
  let backupID = try #require(try files.journals().first?.backupID)
  try files.corruptBackup(backupID)
  let restarted = files.restartSession()
  #expect(throws: (any Error).self) { try restarted.reconcile(prepared.id) }
  #expect(try files.readTarget().data == prepared.after)
  #expect(try files.journals().first?.phase == .prepared)
}

@Test(arguments: ["symlink", "hardlink", "mode", "directory", "fifo"])
func unsafePrivateTargetsAreRejected(_ kind: String) throws {
  let original = Data("# original\n".utf8)
  let files = try PrivateTransactionFiles(original)
  let target = files.directory.appendingPathComponent("target").path
  let spare = files.directory.appendingPathComponent("spare").path
  switch kind {
  case "symlink":
    #expect(rename(target, spare) == 0)
    #expect(symlink(spare, target) == 0)
  case "hardlink": #expect(link(target, spare) == 0)
  case "mode": #expect(chmod(target, 0o666) == 0)
  case "directory":
    #expect(unlink(target) == 0)
    #expect(mkdir(target, 0o700) == 0)
  default:
    #expect(unlink(target) == 0)
    #expect(mkfifo(target, 0o600) == 0)
  }
  let prepared = try plan(original)
  #expect(throws: (any Error).self) {
    try FileTransaction(files: files).commit(SystemTransactionRequest(plan: prepared))
  }
  #expect(try files.journals().isEmpty)
}

@Test(arguments: ["\n", "\r\n", "\r", ""])
func requestPreservesExistingBlockTerminator(_ ending: String) throws {
  let initial = try plan(Data("# foreign\n".utf8))
  var bytes = initial.after
  bytes.removeLast()
  bytes.append(Data(ending.utf8))
  if !ending.isEmpty { bytes.append(Data("# suffix\r\n".utf8)) }
  let prepared = try plan(bytes, source: "203.0.113.5 staging")
  let files = try PrivateTransactionFiles(bytes)
  _ = try #require(
    try FileTransaction(files: files).commit(SystemTransactionRequest(plan: prepared)))
  #expect(try files.readTarget().data == prepared.after)
}

@Test func abortedFollowupKeepsPriorSeparatorOwnership() throws {
  let original = Data("# foreign without terminator".utf8)
  let files = try PrivateTransactionFiles(original)
  let first = try plan(original)
  _ = try FileTransaction(files: files).commit(SystemTransactionRequest(plan: first))
  let second = try plan(first.after, source: "203.0.113.5 staging")
  files.fault = .beforeRename
  #expect(throws: FixtureFailure.injected) {
    try FileTransaction(files: files).commit(SystemTransactionRequest(plan: second))
  }
  let restarted = files.restartSession()
  #expect(try restarted.reconcile(second.id) == .notCommitted)
  let disable = try ApplyPlan.prepare(
    workspace: Workspace(), system: first.after, separatorEvidence: first.separatorEvidence)
  _ = try #require(try restarted.commit(SystemTransactionRequest(plan: disable)))
  #expect(try files.readTarget().data == original)
}

@Test func unexpectedACLAndExtendedAttributeBlockFixtureWrite() throws {
  for acl in [false, true] {
    let original = Data("# original\n".utf8)
    let files = try PrivateTransactionFiles(original)
    let target = files.directory.appendingPathComponent("target")
    if acl {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/chmod")
      process.arguments = ["+a", "everyone allow read", target.path]
      try process.run()
      process.waitUntilExit()
      try #require(process.terminationStatus == 0)
    } else {
      let value: [UInt8] = [1]
      try value.withUnsafeBytes { buffer in
        guard setxattr(target.path, "de.machosts.test", buffer.baseAddress, buffer.count, 0, 0) == 0
        else { throw FixtureFailure.io(errno) }
      }
    }
    let prepared = try plan(original)
    #expect(throws: FixtureFailure.unsafe) {
      try FileTransaction(files: files).commit(SystemTransactionRequest(plan: prepared))
    }
    #expect(try files.journals().isEmpty)
    #expect(try Data(contentsOf: target) == original)
  }
}

@Test func mismatchedReadbackAndInvalidReceiptCannotReportSuccess() throws {
  let original = Data("# original\n".utf8)
  let files = try PrivateTransactionFiles(original)
  let prepared = try plan(original)
  let receipt = try #require(
    try FileTransaction(files: files).commit(SystemTransactionRequest(plan: prepared)))
  let external = Data("# external after commit\n".utf8)
  try files.mutateTarget(external)
  #expect(try FileTransaction(files: files).reconcile(prepared.id) == .unknown)
  try files.mutateTarget(prepared.after)
  var record = try #require(try files.journals().first)
  record.receipt = ApplyReceipt(
    transactionID: UUID(), beforeDigest: receipt.beforeDigest, afterDigest: receipt.afterDigest,
    backupID: receipt.backupID, readback: .verified, cacheFlush: .notAttempted)
  try JSONEncoder().encode(record).write(
    to: files.directory.appendingPathComponent(prepared.id.uuidString + ".journal"))
  #expect(throws: FileTransactionFailure.invalidJournal) {
    try FileTransaction(files: files).reconcile(prepared.id)
  }
  #expect(try files.readTarget().data == prepared.after)
}

@Test(arguments: [
  Data((HostsSyntax.begin + "\n").utf8), Data([0xff]), Data([0]),
])
func invalidTargetBytesStayUntouched(_ original: Data) throws {
  let files = try PrivateTransactionFiles(original)
  let request = SystemTransactionRequest(
    expectedDigest: ContentDigest(original), resultingDigest: ContentDigest(Data()),
    operation: .remove)
  #expect(throws: (any Error).self) { try FileTransaction(files: files).commit(request) }
  #expect(try files.readTarget().data == original)
  #expect(try files.journals().isEmpty)
}

@Test(arguments: [false, true])
func missingJournalNeverReconstructsReceiptFromMatchingBytes(_ afterBytes: Bool) throws {
  let original = Data("# original\n".utf8)
  let files = try PrivateTransactionFiles(original)
  let prepared = try plan(original)
  let transaction = FileTransaction(files: files)
  _ = try #require(try transaction.commit(SystemTransactionRequest(plan: prepared)))
  // Simulate lost evidence after a real fixture commit, not merely an unstarted request.
  try FileManager.default.removeItem(
    at: files.directory.appendingPathComponent(prepared.id.uuidString + ".journal"))
  if !afterBytes { try files.mutateTarget(original) }
  let actual = try files.readTarget()
  let artifacts = try FileManager.default.contentsOfDirectory(atPath: files.directory.path).sorted()
  #expect(try transaction.reconcile(prepared.id) == .missingJournal)
  #expect(try transaction.reconcile(prepared.id) == .missingJournal)
  #expect(try files.readTarget() == actual)
  #expect(try files.journals().isEmpty)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: files.directory.path).sorted() == artifacts)
}
