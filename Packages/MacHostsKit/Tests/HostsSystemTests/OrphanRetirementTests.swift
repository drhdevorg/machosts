import Darwin
import Foundation
import HostsCore
import Testing

@testable import HostsServices
@testable import HostsSystem

private func orphanPlan(_ bytes: Data) throws -> (ApplyPlan, ApplyRetirement) {
  let workspace = Workspace(profiles: [
    Profile(name: "Fixture", source: "203.0.113.9 staging", isEnabled: true)
  ])
  let plan = try ApplyPlan.prepare(workspace: workspace, system: bytes)
  return (plan, try ApplyRetirement(pending: PendingApply(workspace: workspace, plan: plan)))
}

@Test(arguments: [false, true])
func retirementExcludesReplayWithoutInventingHistory(_ lostCommit: Bool) throws {
  let files = try PrivateTransactionFiles(originalBytes)
  let (plan, retirement) = try orphanPlan(originalBytes)
  let transaction = FileTransaction(files: files)
  if lostCommit {
    _ = try transaction.commit(SystemTransactionRequest(plan: plan))
    try FileManager.default.removeItem(
      at: files.directory.appendingPathComponent(plan.id.uuidString + ".journal"))
    try files.mutateTarget(originalBytes)
  }
  let before = try files.readTarget()
  #expect(try transaction.reconcile(plan.id) == .missingJournal)
  #expect(try transaction.retireOrphan(retirement) == retirement)
  #expect(try transaction.retireOrphan(retirement) == retirement)
  #expect(try files.readTarget() == before)
  #expect(try files.journals().isEmpty)
  #expect(try files.retirements() == [retirement])
  #expect(try transaction.reconcile(plan.id) == .retired(retirement))
  #expect(throws: FileTransactionFailure.replay) {
    try transaction.commit(SystemTransactionRequest(plan: plan))
  }
  let changedReplay = SystemTransactionRequest(
    transactionID: plan.id, expectedDigest: ContentDigest(Data()),
    resultingDigest: ContentDigest(Data("# changed request".utf8)), operation: .remove)
  #expect(throws: FileTransactionFailure.replay) { try transaction.commit(changedReplay) }
  // An unrelated new transaction is allowed, and its receipt comes from an actual new write.
  let (next, _) = try orphanPlan(originalBytes)
  _ = try #require(try transaction.commit(SystemTransactionRequest(plan: next)))
  #expect(try files.readTarget().data == next.after)
  #expect(try files.retirements() == [retirement])
}

@Test(arguments: ["after", "foreign", "prepared", "committed", "otherPrepared"])
func retirementRefusesIneligibleOrphans(_ kind: String) throws {
  let files = try PrivateTransactionFiles(originalBytes)
  let (plan, retirement) = try orphanPlan(originalBytes)
  let transaction = FileTransaction(files: files)
  if kind == "prepared" || kind == "committed" || kind == "otherPrepared" {
    let selected = kind == "otherPrepared" ? try orphanPlan(originalBytes).0 : plan
    if kind != "committed" { files.fault = .beforeRename }
    do { _ = try transaction.commit(SystemTransactionRequest(plan: selected)) } catch FixtureFailure
      .injected
    {}
    files.fault = nil
  } else {
    try files.mutateTarget(kind == "after" ? plan.after : Data("# foreign".utf8))
  }
  let before = try files.readTarget()
  let journals = try files.journals()
  #expect(throws: (any Error).self) { try transaction.retireOrphan(retirement) }
  #expect(try files.readTarget() == before)
  #expect(try files.journals() == journals)
  #expect(try files.retirements().isEmpty)
}

@Test(arguments: [false, true])
func retirementSaveFailureLeavesRecoverableFence(_ saved: Bool) throws {
  let files = try PrivateTransactionFiles(originalBytes)
  let (plan, retirement) = try orphanPlan(originalBytes)
  files.retirementInterruption = { after in if after == saved { throw FixtureFailure.injected } }
  let before = try files.readTarget()
  #expect(throws: FixtureFailure.injected) {
    try FileTransaction(files: files).retireOrphan(retirement)
  }
  #expect(try files.readTarget() == before)
  files.retirementInterruption = nil
  let transaction = FileTransaction(files: files)
  #expect(try transaction.reconcile(plan.id) == (saved ? .retired(retirement) : .missingJournal))
  _ = try transaction.retireOrphan(retirement)
  #expect(throws: FileTransactionFailure.replay) {
    try transaction.commit(SystemTransactionRequest(plan: plan))
  }
}

@Test func externalReplacementDuringRetirementKeepsFenceAndBlocksResolution() throws {
  let files = try PrivateTransactionFiles(originalBytes)
  let (plan, retirement) = try orphanPlan(originalBytes)
  files.retirementInterruption = { saved in
    if saved { try files.mutateTarget(Data("# external during retirement".utf8)) }
  }
  #expect(throws: FileTransactionFailure.staleFile) {
    try FileTransaction(files: files).retireOrphan(retirement)
  }
  #expect(try files.retirements() == [retirement])
  #expect(throws: FileTransactionFailure.replay) {
    try FileTransaction(files: files).commit(SystemTransactionRequest(plan: plan))
  }
  #expect(try files.readTarget().data == Data("# external during retirement".utf8))
}

@Test(arguments: ["corrupt", "version", "filename", "conflict", "binding"])
func damagedRetirementEvidenceBlocksNewCommits(_ damage: String) throws {
  let files = try PrivateTransactionFiles(originalBytes)
  let (plan, retirement) = try orphanPlan(originalBytes)
  let transaction = FileTransaction(files: files)
  if damage == "conflict" {
    _ = try transaction.commit(SystemTransactionRequest(plan: plan))
    try files.saveRetirement(retirement)
  } else {
    _ = try transaction.retireOrphan(retirement)
    let url = files.directory.appendingPathComponent(plan.id.uuidString + ".retired")
    if damage == "corrupt" {
      try Data("{".utf8).write(to: url)
    } else if damage == "filename" {
      try FileManager.default.moveItem(
        at: url, to: files.directory.appendingPathComponent(UUID().uuidString + ".retired"))
    } else if damage == "version" {
      var object = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      object["version"] = 99
      try JSONSerialization.data(withJSONObject: object).write(to: url)
    } else {
      let (_, other) = try orphanPlan(Data("# other before".utf8))
      #expect(throws: FileTransactionFailure.invalidJournal) {
        // A record with the same ID but different binding must never replace an existing fence.
        var object = try #require(
          try JSONSerialization.jsonObject(with: JSONEncoder().encode(other)) as? [String: Any])
        object["transactionID"] = retirement.transactionID.uuidString
        let changed = try JSONDecoder().decode(
          ApplyRetirement.self, from: JSONSerialization.data(withJSONObject: object))
        _ = try transaction.retireOrphan(changed)
      }
      #expect(try files.retirements() == [retirement])
      return
    }
  }
  let target = try files.readTarget()
  #expect(throws: (any Error).self) { try transaction.reconcile(plan.id) }
  let next = SystemTransactionRequest(
    expectedDigest: ContentDigest(target.data), resultingDigest: ContentDigest(Data()),
    operation: .remove)
  #expect(throws: (any Error).self) { try transaction.commit(next) }
  #expect(try files.readTarget() == target)
}

extension DiskApplyEnvironment {
  func interruptRetirement(at point: String) {
    files.retirementInterruption = { saved in
      if point == (saved ? "fenceSaved" : "beforeFence") { _exit(86) }
    }
    files.retirementRenameInterruption = { renamed in
      if point == (renamed ? "fenceAfterRename" : "fenceBeforeRename") { _exit(86) }
    }
  }
}

/// Fresh subprocess actions reached only through the existing private fixture harness.
func runRetirementWorker(_ directory: URL, action: String, point: String) async throws -> Bool {
  guard action.hasPrefix("retire") else { return false }
  if action == "retireReplay" {
    let pending = try JSONDecoder().decode(
      PendingApply.self, from: Data(contentsOf: directory.appendingPathComponent("pending.json")))
    let plan = try ApplyPlan.prepare(workspace: pending.workspace, system: originalBytes)
    let generated = SystemTransactionRequest(plan: plan)
    let delayed = SystemTransactionRequest(
      transactionID: pending.transactionID, expectedDigest: pending.beforeDigest,
      resultingDigest: pending.afterDigest, operation: generated.operation)
    let files = try PrivateTransactionFiles(reopening: directory)
    #expect(throws: FileTransactionFailure.replay) {
      try FileTransaction(files: files).commit(delayed)
    }
    #expect(try files.readTarget().data == originalBytes)
    return true
  }
  let store = try await WorkspaceStore.open(
    directory: directory.appendingPathComponent("workspace"),
    fault: { boundary in
      if action == "retireCrash" {
        switch boundary {
        case .beforeWrite: if point == "appBeforeWrite" { _exit(86) }
        case .beforeRename: if point == "appBeforeRename" { _exit(86) }
        case .afterRename: if point == "appAfterRename" { _exit(86) }
        }
      }
    })
  let snapshot = try #require(await store.state().snapshot)
  let environment = try DiskApplyEnvironment(directory: directory)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  if action == "retireCrash" {
    let pending = try #require(snapshot.pendingApply)
    try JSONEncoder().encode(pending).write(to: directory.appendingPathComponent("pending.json"))
    await environment.interruptRetirement(at: point)
    _ = try await coordinator.retireOrphan(transactionID: pending.transactionID)
    Issue.record("Retirement did not reach interruption")
    return true
  }
  #expect(action == "retireRecover")
  if let pending = snapshot.pendingApply {
    if point == "beforeFence" || point == "fenceBeforeRename" {
      #expect(try await coordinator.reconcile() == .recoveryRequired)
      #expect(await coordinator.recoveryAssessment()?.evidence == .missingJournal)
      _ = try await coordinator.retireOrphan(transactionID: pending.transactionID)
    } else {
      #expect(try await coordinator.reconcile() == .unconfirmed)
      #expect(await coordinator.recoveryAssessment()?.evidence == .retired)
    }
  }
  let resolved = try #require(await store.state().snapshot)
  #expect(resolved.pendingApply == nil)
  #expect(resolved.applied == snapshot.applied)
  #expect(resolved.draft == snapshot.draft)
  #expect(try await environment.readSystem() == originalBytes)
  // A new preview uses a new transaction identity and does not repeat the abandoned request.
  _ = try await coordinator.prepare()
  return true
}

@Test func retirementSurvivesProcessExitAndRejectsDelayedWorker() async throws {
  for point in [
    "beforeFence", "fenceBeforeRename", "fenceAfterRename", "fenceSaved", "appBeforeWrite",
    "appBeforeRename", "appAfterRename",
  ] {
    let directory = try retainedFixture()
    defer { cleanup(directory) }
    #expect(try await runWorker(directory, action: "beforeCommit") == 86)
    #expect(try await runWorker(directory, action: "retireCrash", point: point) == 86)
    #expect(try await runWorker(directory, action: "retireRecover", point: point) == 0)
    #expect(try await runWorker(directory, action: "retireReplay") == 0)
  }
}

@Test func retirementPersistenceMustFinishBeforeTerminalEvidence() throws {
  let files = try PrivateTransactionFiles(originalBytes)
  let (plan, retirement) = try orphanPlan(originalBytes)
  let transaction = FileTransaction(files: files)
  files.retirementSyncFailure = true
  let before = try files.readTarget()
  #expect(throws: FixtureFailure.injected) { try transaction.retireOrphan(retirement) }
  #expect(throws: FixtureFailure.injected) { try transaction.reconcile(plan.id) }
  #expect(throws: FileTransactionFailure.replay) {
    try transaction.commit(SystemTransactionRequest(plan: plan))
  }
  #expect(try files.readTarget() == before)
  files.retirementSyncFailure = false
  #expect(try transaction.reconcile(plan.id) == .retired(retirement))
}
