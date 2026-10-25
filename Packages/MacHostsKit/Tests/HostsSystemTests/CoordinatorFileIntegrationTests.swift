import Darwin
import Foundation
import HostsCore
import Testing

@testable import HostsServices
@testable import HostsSystem

/// The entire adapter lives in the test bundle. Its target is always a newly created fixture.
actor DiskApplyEnvironment: ApplyEnvironment {
  let files: PrivateTransactionFiles
  let crash: String?
  var authorizations = 0

  init(directory: URL, crash: String? = nil) throws {
    files = try PrivateTransactionFiles(reopening: directory)
    self.crash = crash
    files.interruption = { point in
      if point.rawValue == crash { _exit(86) }
    }
  }

  func readSystem() throws -> Data { try files.readTarget().data }
  func authorize(_ planID: UUID) { authorizations += 1 }
  func authorizationCount() -> Int { authorizations }
  func commit(_ plan: ApplyPlan) throws -> ApplyReceipt {
    if crash == "beforeCommit" { _exit(86) }
    let receipt = try #require(
      try FileTransaction(files: files).commit(SystemTransactionRequest(plan: plan)))
    if crash == "afterCommit" { _exit(86) }
    return receipt
  }
  func retireOrphan(_ retirement: ApplyRetirement) throws -> ApplyRetirement {
    try FileTransaction(files: files).retireOrphan(retirement)
  }
  func outcome(for transactionID: UUID) throws -> ApplyTransactionOutcome {
    switch try FileTransaction(files: files).reconcile(transactionID) {
    case .committed(let receipt): return .committed(receipt)
    case .notCommitted: return .notCommitted
    case .retired(let retirement): return .retired(retirement)
    case .missingJournal: return .missingJournal
    case .unknown: return .unknown
    }
  }
}

let originalBytes = Data("127.0.0.1 localhost\r\n# foreign without terminator".utf8)

func retainedFixture() throws -> URL {
  try PrivateTransactionFiles(originalBytes, cleanupOnDeinit: false).directory
}

func seed(_ directory: URL) async throws -> WorkspaceStore {
  let store = try await WorkspaceStore.open(
    directory: directory.appendingPathComponent("workspace"))
  _ = try await store.saveDraft(
    Workspace(
      revision: 1,
      profiles: [Profile(name: "Staging", source: "203.0.113.42 staging", isEnabled: true)]),
    expectedGeneration: 0)
  return store
}

@Test func coordinatorUsesRealBackupJournalAndSeparatorEvidence() async throws {
  let directory = try retainedFixture()
  defer { cleanup(directory) }
  let store = try await seed(directory)
  let environment = try DiskApplyEnvironment(directory: directory)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  try await coordinator.apply(planID: plan.id)
  let applied = try #require(await store.state().snapshot?.applied)
  #expect(applied.receipt.afterDigest == plan.resultingSystemDigest)
  #expect(try await coordinator.reconcile() == .confirmed)
  let unchanged = try await coordinator.prepare()
  try await coordinator.apply(planID: unchanged.id)
  #expect(await environment.authorizationCount() == 1)
  let snapshot = try #require(await store.state().snapshot)
  var disabled = snapshot.draft
  disabled.revision += 1
  disabled.profiles[0].isEnabled = false
  _ = try await store.saveDraft(disabled, expectedGeneration: snapshot.generation)
  let removal = try await coordinator.prepare()
  try await coordinator.apply(planID: removal.id)
  #expect(try await environment.readSystem() == originalBytes)
  // Check the independently persisted backup through the same locked session.
  #expect(try await environment.backup(applied.receipt.backupID) == originalBytes)
}

extension DiskApplyEnvironment {
  fileprivate func backup(_ id: UUID) throws -> Data { try files.readBackup(id).data }
}

/// SwiftPM launches a fresh test process for this one selected test. Normal suite runs do nothing.
@Test func privateProcessWorker() async throws {
  let variables = ProcessInfo.processInfo.environment
  guard let path = variables["MACHOSTS_FIXTURE_WORKER"],
    let action = variables["MACHOSTS_FIXTURE_ACTION"]
  else { return }
  let directory = URL(fileURLWithPath: path, isDirectory: true)
  if try await runRetirementWorker(
    directory, action: action, point: variables["MACHOSTS_FIXTURE_POINT"] ?? "")
  {
    return
  }
  if try await runLifecycleWorker(
    directory, action: action, point: variables["MACHOSTS_FIXTURE_POINT"] ?? "")
  {
    return
  }
  if action == "lock" {
    #expect(throws: FixtureFailure.locked) { try PrivateTransactionFiles(reopening: directory) }
    await #expect(throws: WorkspaceStoreFailure.alreadyOpen) {
      try await WorkspaceStore.open(directory: directory.appendingPathComponent("workspace"))
    }
    return
  }
  if action == "blocked" {
    let store = try await WorkspaceStore.open(
      directory: directory.appendingPathComponent("workspace"))
    let before = try #require(await store.state().snapshot)
    let environment = try DiskApplyEnvironment(directory: directory)
    let bytes = try await environment.readSystem()
    let coordinator = ApplyCoordinator(store: store, environment: environment)
    if variables["MACHOSTS_FIXTURE_POINT"] == "corruptBackup" {
      await #expect(throws: FileTransactionFailure.backupMismatch) {
        try await coordinator.reconcile()
      }
    } else {
      #expect(try await coordinator.reconcile() == .recoveryRequired)
    }
    #expect(await coordinator.state() == .recoveryRequired)
    #expect(await store.state().snapshot == before)
    #expect(try await environment.readSystem() == bytes)
    await #expect(throws: ApplyCoordinatorFailure.recoveryRequired) {
      try await coordinator.prepare()
    }
    return
  }
  if action == "recover" {
    let store = try await WorkspaceStore.open(
      directory: directory.appendingPathComponent("workspace"))
    let pending = try #require(await store.state().snapshot?.pendingApply)
    let environment = try DiskApplyEnvironment(directory: directory)
    let coordinator = ApplyCoordinator(store: store, environment: environment)
    let point = try #require(variables["MACHOSTS_FIXTURE_POINT"])
    let committed = ["afterRename", "readback", "receipt", "afterCommit"].contains(point)
    let unknown = ["beforeCommit", "backup", "prepared"].contains(point)
    let expected: SystemObservation =
      committed ? .confirmed : unknown ? .recoveryRequired : .unconfirmed
    #expect(try await coordinator.reconcile() == expected)
    let snapshot = try #require(await store.state().snapshot)
    #expect((snapshot.pendingApply != nil) == unknown)
    #expect((snapshot.applied != nil) == committed)
    let actual = try await environment.readSystem()
    #expect(ContentDigest(actual) == (committed ? pending.afterDigest : pending.beforeDigest))
    if unknown {
      let assessment = try #require(await coordinator.recoveryAssessment())
      #expect(assessment.evidence == .missingJournal)
      #expect(assessment.fileState == .before)
      #expect(assessment.transactionID == pending.transactionID)
      await #expect(throws: ApplyCoordinatorFailure.recoveryRequired) {
        try await coordinator.prepare()
      }
    } else {
      // A second reconciliation is idempotent, and a recovered commit can be disabled exactly.
      #expect(try await coordinator.reconcile() == (committed ? .confirmed : .unconfirmed))
      if committed {
        var disabled = snapshot.draft
        disabled.revision += 1
        disabled.profiles[0].isEnabled = false
        _ = try await store.saveDraft(disabled, expectedGeneration: snapshot.generation)
        let removal = try await coordinator.prepare()
        try await coordinator.apply(planID: removal.id)
        #expect(try await environment.readSystem() == originalBytes)
      }
    }
    return
  }
  let store = try await seed(directory)
  let environment = try DiskApplyEnvironment(directory: directory, crash: action)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  try await coordinator.apply(planID: plan.id)
  Issue.record("Worker did not reach the requested interruption")
}

/// Run the current, already-built test bundle directly through SwiftPM's installed test runner.
/// A separate log avoids pipe backpressure; a deadline prevents a stuck child hanging the suite.
func startFixtureWorker(_ directory: URL, action: String, point: String = "") throws -> Process {
  let runner = URL(fileURLWithPath: CommandLine.arguments[0])
  guard runner.lastPathComponent == "swiftpm-testing-helper",
    let executable = Bundle(for: BundleAnchor.self).executableURL
  else { throw FixtureFailure.unsafe }
  let log = directory.appendingPathComponent("worker-" + UUID().uuidString + ".log")
  guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
    throw FixtureFailure.unsafe
  }
  let output = try FileHandle(forWritingTo: log)
  defer {
    do { try output.close() } catch { Issue.record("Worker log close failed: \(error)") }
  }
  let child = Process()
  child.executableURL = runner
  child.arguments = [
    "--test-bundle-path", executable.path, "--testing-library", "swift-testing",
    "--filter", "privateProcessWorker",
  ]
  var variables = ProcessInfo.processInfo.environment
  variables["MACHOSTS_FIXTURE_WORKER"] = directory.path
  variables["MACHOSTS_FIXTURE_ACTION"] = action
  variables["MACHOSTS_FIXTURE_POINT"] = point
  child.environment = variables
  child.standardOutput = output
  child.standardError = output
  try child.run()
  return child
}

func runWorker(_ directory: URL, action: String, point: String = "") async throws -> Int32 {
  let child = try startFixtureWorker(directory, action: action, point: point)
  defer {
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
  }
  let deadline = ContinuousClock.now.advanced(by: .seconds(30))
  while child.isRunning && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(25))
  }
  if child.isRunning {
    guard kill(child.processIdentifier, SIGKILL) == 0 else {
      throw FixtureFailure.io(errno)
    }
    throw FixtureFailure.injected
  }
  if [
    "recover", "lock", "blocked", "recoverSave", "observeWorker", "retireRecover", "retireReplay",
  ].contains(action) {
    if child.terminationStatus != 0 {
      let logs = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      for log in logs where log.pathExtension == "log" {
        Issue.record(
          "Fixture worker log: \(String(decoding: try Data(contentsOf: log), as: UTF8.self))")
      }
    }
  }
  return child.terminationStatus
}

private final class BundleAnchor: NSObject {}

@Test func realProcessExitReopensCoordinatorAndFileJournals() async throws {
  for point in [
    "beforeCommit", "backup", "prepared", "beforeRename", "afterRename", "readback", "receipt",
    "afterCommit",
  ] {
    let directory = try retainedFixture()
    defer { cleanup(directory) }
    let status = try await runWorker(directory, action: point)
    #expect(status == 86)
    // A persisted app intent proves the child actually entered the commit boundary.
    let snapshot = try JSONDecoder().decode(
      WorkspaceSnapshot.self,
      from: Data(contentsOf: directory.appendingPathComponent("workspace/workspace.json")))
    #expect(snapshot.pendingApply != nil)
    #expect(snapshot.applied == nil)
    #expect(try await runWorker(directory, action: "recover", point: point) == 0)
  }
}

@Test func independentProcessCannotEnterLockedFixture() async throws {
  let files = try PrivateTransactionFiles(originalBytes)
  let store = try await seed(files.directory)
  #expect(try await runWorker(files.directory, action: "lock") == 0)
  #expect(await store.state().snapshot?.draft.revision == 1)
  #expect(try files.readTarget().data == originalBytes)
}

func cleanup(_ directory: URL) {
  do { try FileManager.default.removeItem(at: directory) } catch {
    Issue.record("Fixture cleanup failed: \(error)")
  }
}

@Test func restartedCoordinatorPreservesUnknownOrDamagedEvidence() async throws {
  for damage in ["externalBytes", "corruptBackup"] {
    let directory = try retainedFixture()
    defer { cleanup(directory) }
    #expect(try await runWorker(directory, action: "afterRename") == 86)
    try damageInterruptedFixture(directory, damage: damage)
    #expect(try await runWorker(directory, action: "blocked", point: damage) == 0)
  }
}

private func damageInterruptedFixture(_ directory: URL, damage: String) throws {
  let files = try PrivateTransactionFiles(reopening: directory)
  if damage == "corruptBackup" {
    let record = try #require(try files.journals().first)
    // Keep the JSON readable but invalidate the backed-up bytes to exercise digest validation.
    var backup = try files.readBackup(record.backupID)
    backup = TransactionSnapshot(
      data: Data("# altered backup".utf8), device: backup.device, inode: backup.inode,
      modificationSeconds: backup.modificationSeconds,
      modificationNanoseconds: backup.modificationNanoseconds,
      changeSeconds: backup.changeSeconds, changeNanoseconds: backup.changeNanoseconds,
      metadata: backup.metadata)
    try JSONEncoder().encode(backup).write(
      to: directory.appendingPathComponent(record.backupID.uuidString + ".backup"))
  } else {
    try files.mutateTarget(Data("# newer foreign content\r\n192.0.2.8 vpn\r\n".utf8))
  }
}
