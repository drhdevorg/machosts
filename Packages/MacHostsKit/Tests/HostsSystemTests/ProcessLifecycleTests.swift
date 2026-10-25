import Darwin
import Foundation
import HostsCore
import Synchronization
import Testing

@testable import HostsServices
@testable import HostsSystem

/// Test-only transport between unprivileged fixture processes. This is deliberately not
/// the production IPC format: its directory and all inputs are owned by this test harness.
private struct FixtureRequest: Codable {
  let id: UUID
  let before: ContentDigest
  let after: ContentDigest
  let block: Data

  init(_ plan: ApplyPlan) throws {
    let request = SystemTransactionRequest(plan: plan)
    guard case .replace(let block) = request.operation else { throw FixtureFailure.unsafe }
    id = request.transactionID
    before = request.expectedDigest
    after = request.resultingDigest
    self.block = block
  }

  var transaction: SystemTransactionRequest {
    SystemTransactionRequest(
      transactionID: id, expectedDigest: before, resultingDigest: after,
      operation: .replace(block))
  }
}

/// No persistent file-session lock in the app: the independently running worker owns it.
private actor IndependentApplyEnvironment: ApplyEnvironment {
  let directory: URL
  let pause: String?
  let store: WorkspaceStore

  init(directory: URL, store: WorkspaceStore, pause: String? = nil) {
    self.directory = directory
    self.store = store
    self.pause = pause
  }

  func readSystem() throws -> Data {
    // Only the harness-created target is read here, including while the worker holds its lock.
    try Data(contentsOf: directory.appendingPathComponent("target"))
  }

  func authorize(_ planID: UUID) {}

  func commit(_ plan: ApplyPlan) async throws -> ApplyReceipt {
    guard let pause else { throw FixtureFailure.unsafe }
    try JSONEncoder().encode(FixtureRequest(plan)).write(
      to: directory.appendingPathComponent("request.json"), options: .atomic)
    let worker = try startFixtureWorker(directory, action: "independentCommit", point: pause)
    defer { if worker.isRunning { kill(worker.processIdentifier, SIGKILL) } }
    try Data(String(worker.processIdentifier).utf8).write(
      to: directory.appendingPathComponent("worker.pid"))
    try await waitForFixtureFile(directory, name: "paused")
    // An edit confirmed while commit is in flight must survive both app exit and recovery.
    let snapshot = try #require(await store.state().snapshot)
    var newer = snapshot.draft
    newer.revision += 1
    newer.profiles[0].source = "203.0.113.43 newer-draft"
    _ = try await store.saveDraft(newer, expectedGeneration: snapshot.generation)
    _exit(86)
  }

  func retireOrphan(_ retirement: ApplyRetirement) throws -> ApplyRetirement {
    let files = try PrivateTransactionFiles(reopening: directory)
    return try FileTransaction(files: files).retireOrphan(retirement)
  }

  func outcome(for transactionID: UUID) throws -> ApplyTransactionOutcome {
    let files: PrivateTransactionFiles
    do { files = try PrivateTransactionFiles(reopening: directory) } catch FixtureFailure.locked {
      // A live worker, even with after-bytes visible, cannot be declared terminal.
      return .workerActive
    }
    switch try FileTransaction(files: files).reconcile(transactionID) {
    case .committed(let receipt): return .committed(receipt)
    case .notCommitted: return .notCommitted
    case .retired(let retirement): return .retired(retirement)
    case .missingJournal: return .missingJournal
    case .unknown: return .unknown
    }
  }
}

private func waitForFixtureFile(_ directory: URL, name: String) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(15))
  while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
    guard ContinuousClock.now < deadline else { throw FixtureFailure.injected }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private func seedAndRelease(_ directory: URL) async throws {
  _ = try await seed(directory)
}

private func writePointName(_ point: WorkspaceWritePoint) -> String {
  switch point {
  case .beforeWrite: "beforeWrite"
  case .beforeRename: "beforeRename"
  case .afterRename: "afterRename"
  }
}

/// Called only by the selected privateProcessWorker entry in a fresh process.
func runLifecycleWorker(_ directory: URL, action: String, point: String) async throws -> Bool {
  if action == "saveCrash" {
    if !point.hasPrefix("recovery:") { try await seedAndRelease(directory) }
    let count = Mutex(0)
    let parts = point.split(separator: ":").map(String.init)
    let selectedSave = parts[0] == "applied" ? 2 : 1
    let store = try await WorkspaceStore.open(
      directory: directory.appendingPathComponent("workspace"),
      fault: { current in
        let ordinal = count.withLock { value in
          if current == .beforeWrite { value += 1 }
          return value
        }
        if ordinal == selectedSave, writePointName(current) == parts[1] { _exit(86) }
      })
    let environment = try DiskApplyEnvironment(directory: directory)
    let coordinator = ApplyCoordinator(store: store, environment: environment)
    if parts[0] == "recovery" {
      _ = try await coordinator.reconcile()
    } else {
      let plan = try await coordinator.prepare()
      try await coordinator.apply(planID: plan.id)
    }
    Issue.record("App save did not reach the requested interruption")
    return true
  }
  if action == "recoverSave" {
    let store = try await WorkspaceStore.open(
      directory: directory.appendingPathComponent("workspace"))
    let before = try #require(await store.state().snapshot)
    let environment = try DiskApplyEnvironment(directory: directory)
    let coordinator = ApplyCoordinator(store: store, environment: environment)
    let intent = point.hasPrefix("intent:")
    let unknown = point == "intent:afterRename"
    #expect(before.draft.revision == 1)
    let resolved = point.hasSuffix(":afterRename") && !intent
    #expect((before.pendingApply != nil) == (unknown || (!intent && !resolved)))
    #expect((before.applied != nil) == resolved)
    #expect(
      try await coordinator.reconcile()
        == (unknown ? .recoveryRequired : intent ? .unconfirmed : .confirmed))
    let after = try #require(await store.state().snapshot)
    #expect(after.draft == before.draft)
    #expect((after.pendingApply != nil) == unknown)
    #expect((after.applied != nil) == !intent)
    #expect(try await environment.readSystem() == (intent ? originalBytes : expectedAppliedBytes()))
    if unknown {
      #expect(after == before)
      await #expect(throws: ApplyCoordinatorFailure.recoveryRequired) {
        try await coordinator.prepare()
      }
    } else {
      #expect(try await coordinator.reconcile() == (intent ? .unconfirmed : .confirmed))
    }
    return true
  }
  if action == "independentApp" {
    let store = try await seed(directory)
    let environment = IndependentApplyEnvironment(directory: directory, store: store, pause: point)
    let coordinator = ApplyCoordinator(store: store, environment: environment)
    let plan = try await coordinator.prepare()
    try await coordinator.apply(planID: plan.id)
    Issue.record("App did not exit while its independent worker was paused")
    return true
  }
  if action == "independentCommit" {
    let request = try JSONDecoder().decode(
      FixtureRequest.self, from: Data(contentsOf: directory.appendingPathComponent("request.json")))
    let files = try PrivateTransactionFiles(reopening: directory)
    files.interruption = { current in
      guard current.rawValue == point else { return }
      do {
        try Data().write(to: directory.appendingPathComponent("paused"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("release").path)
        {
          guard ContinuousClock.now < deadline else { _exit(87) }
          Thread.sleep(forTimeInterval: 0.01)
        }
      } catch { _exit(88) }
    }
    let receipt = try #require(try FileTransaction(files: files).commit(request.transaction))
    #expect(receipt.transactionID == request.id)
    // The parent checks the persisted terminal journal independently, never this marker alone.
    try Data().write(to: directory.appendingPathComponent("finished"))
    return true
  }
  if action == "observeWorker" {
    let store = try await WorkspaceStore.open(
      directory: directory.appendingPathComponent("workspace"))
    let environment = IndependentApplyEnvironment(directory: directory, store: store)
    let coordinator = ApplyCoordinator(store: store, environment: environment)
    let before = try #require(await store.state().snapshot)
    let pending = try #require(before.pendingApply)
    let bytes = try await environment.readSystem()
    let running = point == "running"
    let committed = point == "committed"
    #expect(before.draft.revision == 2)
    #expect(before.draft.profiles[0].source == "203.0.113.43 newer-draft")
    #expect(pending.workspace.revision == 1)
    #expect(before.applied == nil)
    #expect(
      try await coordinator.reconcile()
        == (running ? .recoveryRequired : committed ? .confirmed : .unconfirmed))
    let after = try #require(await store.state().snapshot)
    #expect(after.draft == before.draft)
    #expect(try await environment.readSystem() == bytes)
    if running {
      #expect(await coordinator.recoveryAssessment()?.evidence == .workerActive)
      #expect(after == before)
      await #expect(throws: FixtureFailure.locked) {
        try await coordinator.retireOrphan(transactionID: pending.transactionID)
      }
      #expect(await store.state().snapshot == before)
      #expect(await store.isApplyInFlight() == false)
      #expect(try await coordinator.reconcile() == .recoveryRequired)
      await #expect(throws: ApplyCoordinatorFailure.recoveryRequired) {
        try await coordinator.prepare()
      }
    } else {
      #expect(after.pendingApply == nil)
      #expect((after.applied != nil) == committed)
      if let applied = after.applied {
        #expect(applied.workspace == pending.workspace)
        #expect(applied.receipt.transactionID == pending.transactionID)
        #expect(applied.receipt.afterDigest == ContentDigest(bytes))
      }
      #expect(try await coordinator.reconcile() == (committed ? .confirmed : .unconfirmed))
      let next = try await coordinator.prepare()
      #expect(next.workspaceRevision == 2)
      #expect(next.after != bytes)
    }
    return true
  }
  return false
}

private func expectedAppliedBytes() throws -> Data {
  try ApplyPlan.prepare(
    workspace: Workspace(
      revision: 1,
      profiles: [Profile(name: "Staging", source: "203.0.113.42 staging", isEnabled: true)]),
    system: originalBytes
  ).after
}

@Test func processExitDuringIntentAndAppliedSnapshotPublication() async throws {
  for save in ["intent", "applied"] {
    for boundary in ["beforeWrite", "beforeRename", "afterRename"] {
      let directory = try retainedFixture()
      defer { cleanup(directory) }
      let point = save + ":" + boundary
      #expect(try await runWorker(directory, action: "saveCrash", point: point) == 86)
      #expect(try await runWorker(directory, action: "recoverSave", point: point) == 0)
    }
  }
}

@Test func processExitDuringRecoveredSnapshotPublication() async throws {
  for boundary in ["beforeWrite", "beforeRename", "afterRename"] {
    let directory = try retainedFixture()
    defer { cleanup(directory) }
    #expect(try await runWorker(directory, action: "afterCommit") == 86)
    let point = "recovery:" + boundary
    #expect(try await runWorker(directory, action: "saveCrash", point: point) == 86)
    #expect(try await runWorker(directory, action: "recoverSave", point: point) == 0)
  }
}

private func waitForReleasedTransactionLock(_ directory: URL) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(15))
  while true {
    do {
      _ = try PrivateTransactionFiles(reopening: directory)
      return
    } catch FixtureFailure.locked {
      guard ContinuousClock.now < deadline else { throw FixtureFailure.injected }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

@Test func independentWorkerOutlivesAppAndBlocksPrematureRecovery() async throws {
  for pause in ["beforeRename", "afterRename"] {
    for finish in ["complete", "kill"] {
      let directory = try retainedFixture()
      defer { cleanup(directory) }
      #expect(try await runWorker(directory, action: "independentApp", point: pause) == 86)
      let pidText = try String(
        contentsOf: directory.appendingPathComponent("worker.pid"), encoding: .utf8)
      let pid = try #require(Int32(pidText))
      var released = false
      defer { if !released { kill(pid, SIGKILL) } }
      #expect(kill(pid, 0) == 0)
      // The app process and its workspace lock are gone; the worker is still paused with its own lock.
      #expect(try await runWorker(directory, action: "observeWorker", point: "running") == 0)
      if finish == "kill" {
        #expect(kill(pid, SIGKILL) == 0)
      } else {
        try Data().write(to: directory.appendingPathComponent("release"))
        try await waitForFixtureFile(directory, name: "finished")
      }
      try await waitForReleasedTransactionLock(directory)
      released = true
      let committed = finish == "complete" || pause == "afterRename"
      #expect(
        try await runWorker(
          directory, action: "observeWorker", point: committed ? "committed" : "notCommitted") == 0)
    }
  }
}
