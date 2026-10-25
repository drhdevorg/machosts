import Foundation
import HostsCore
import Synchronization
import Testing

@testable import HostsServices

private actor ApplyGate {
  private var arrived = false
  private var arrival: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?

  func pause() async {
    arrived = true
    arrival?.resume()
    arrival = nil
    await withCheckedContinuation { release = $0 }
  }

  func waitForArrival() async {
    if !arrived { await withCheckedContinuation { arrival = $0 } }
  }

  func resume() {
    release?.resume()
    release = nil
  }
}

/// System bytes live only in test memory. App journaling uses a private on-disk workspace.
private actor FixtureApplyEnvironment: ApplyEnvironment {
  enum Mode: Sendable {
    case success, cacheFailure, notCommitted, unknownBefore, unknownAfter, missingBefore,
      missingAfter, badReceipt, badReadback
  }
  var bytes = Data("# foreign without final newline".utf8)
  var mode: Mode = .success
  var authorizationFailure: ApplyCoordinatorFailure?
  let authorizationGate: ApplyGate?
  let commitGate: ApplyGate?
  var authorizations = 0
  var commits = 0
  var savedReceipt: ApplyReceipt?

  init(authorizationGate: ApplyGate? = nil, commitGate: ApplyGate? = nil) {
    self.authorizationGate = authorizationGate
    self.commitGate = commitGate
  }
  func configure(_ mode: Mode) { self.mode = mode }
  func rejectAuthorization() { authorizationFailure = .cancelled }
  func replace(_ data: Data) { bytes = data }
  func readSystem() -> Data { bytes }
  func counts() -> (Int, Int) { (authorizations, commits) }
  func authorize(_ planID: UUID) async throws {
    authorizations += 1
    await authorizationGate?.pause()
    if let authorizationFailure { throw authorizationFailure }
  }
  func commit(_ plan: ApplyPlan) async throws -> ApplyReceipt {
    commits += 1
    guard ContentDigest(bytes) == plan.expectedSystemDigest else {
      throw ApplyCoordinatorFailure.notCommitted
    }
    if mode == .notCommitted { throw ApplyCoordinatorFailure.notCommitted }
    if mode == .unknownBefore || mode == .missingBefore { throw CancellationError() }
    bytes = plan.after
    let receipt = ApplyReceipt(
      transactionID: mode == .badReceipt ? UUID() : plan.id,
      beforeDigest: plan.expectedSystemDigest, afterDigest: plan.resultingSystemDigest,
      backupID: UUID(), readback: .verified,
      cacheFlush: mode == .cacheFailure ? .failed : .succeeded)
    savedReceipt = mode == .missingAfter ? nil : receipt
    await commitGate?.pause()
    if mode == .unknownAfter || mode == .missingAfter { throw CancellationError() }
    if mode == .badReadback { bytes = Data("# external replacement".utf8) }
    return receipt
  }
  func outcome(for transactionID: UUID) -> ApplyTransactionOutcome {
    if let savedReceipt { return .committed(savedReceipt) }
    return mode == .unknownBefore ? .notCommitted : .unknown
  }
}

private struct ApplyFixture {
  let directory: URL
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "machosts-apply-" + UUID().uuidString, isDirectory: true)
  }
  func open() async throws -> WorkspaceStore {
    try await WorkspaceStore.open(directory: directory)
  }
  func cleanup() {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Apply fixture cleanup failed: \(error)")
    }
  }
}

private func applyDraft(_ revision: UInt64 = 1) -> Workspace {
  Workspace(
    revision: revision,
    profiles: [Profile(name: "Staging", source: "203.0.113.42 staging", isEnabled: true)])
}

@Test func applySuccessNoOpDisableAndExternalObservation() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let environment = FixtureApplyEnvironment()
  let original = await environment.readSystem()
  let desired = applyDraft()
  _ = try await store.saveDraft(desired, expectedGeneration: 0)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  try await coordinator.apply(planID: plan.id)
  #expect(
    await store.state().snapshot?.applied?.workspace == desired)
  #expect(await store.state().snapshot?.pendingApply == nil)
  #expect(try await coordinator.reconcile() == .confirmed)
  let noOp = try await coordinator.prepare()
  #expect(noOp.operation == .noChange)
  try await coordinator.apply(planID: noOp.id)
  #expect(await coordinator.state() == .unchanged)
  #expect(await environment.counts().0 == 1)
  let snapshot = try #require(await store.state().snapshot)
  var disabled = snapshot.draft
  disabled.revision += 1
  disabled.profiles[0].isEnabled = false
  _ = try await store.saveDraft(disabled, expectedGeneration: snapshot.generation)
  let removal = try await coordinator.prepare()
  #expect(removal.operation == .removeManagedBlock)
  try await coordinator.apply(planID: removal.id)
  #expect(await environment.readSystem() == original)
  await environment.replace(Data("# external".utf8))
  #expect(try await coordinator.reconcile() == .externalChange)
}

@Test(arguments: [true, false])
func authorizationSuspensionRejectsSecondClickAndStalePlan(changeDraft: Bool) async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  _ = try await store.saveDraft(applyDraft(), expectedGeneration: 0)
  let gate = ApplyGate()
  let environment = FixtureApplyEnvironment(authorizationGate: gate)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  let running = Task { try await coordinator.apply(planID: plan.id) }
  await gate.waitForArrival()
  await #expect(throws: ApplyCoordinatorFailure.busy) {
    try await coordinator.apply(planID: plan.id)
  }
  await #expect(throws: ApplyCoordinatorFailure.busy) { try await coordinator.prepare() }
  if changeDraft {
    _ = try await store.saveDraft(applyDraft(2), expectedGeneration: 1)
  } else {
    await environment.replace(Data("# external".utf8))
  }
  await gate.resume()
  await #expect(throws: ApplyCoordinatorFailure.stalePlan) { try await running.value }
  #expect(await environment.counts().1 == 0)
  #expect(await store.state().snapshot?.applied == nil)
}

@Test(arguments: [false, true])
func cancellationBeforeCommitNeverRecordsApplied(cancelTask: Bool) async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  _ = try await store.saveDraft(applyDraft(), expectedGeneration: 0)
  let gate = ApplyGate()
  let environment = FixtureApplyEnvironment(authorizationGate: gate)
  if !cancelTask { await environment.rejectAuthorization() }
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  let task = Task { try await coordinator.apply(planID: plan.id) }
  await gate.waitForArrival()
  if cancelTask { task.cancel() }
  await gate.resume()
  do {
    try await task.value
    Issue.record("Expected cancellation")
  } catch {}
  #expect(await coordinator.state() == .cancelled)
  #expect(await environment.counts().1 == 0)
  #expect(await store.state().snapshot?.pendingApply == nil)
  #expect(await store.state().snapshot?.applied == nil)
}

@Test(arguments: [false, true])
func appliedSnapshotPreservesNewDraftAndAutosaveAcrossJournalGenerations(cancelAfterCommit: Bool)
  async throws
{
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let initial = applyDraft()
  _ = try await store.saveDraft(initial, expectedGeneration: 0)
  let autosave = try await WorkspaceAutosave.open(store: store, delay: .seconds(60))
  let gate = ApplyGate()
  let environment = FixtureApplyEnvironment(commitGate: gate)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  let task = Task { try await coordinator.apply(planID: plan.id) }
  await gate.waitForArrival()
  let second = ApplyCoordinator(store: store, environment: environment)
  await #expect(throws: ApplyCoordinatorFailure.busy) { try await second.reconcile() }
  var newer = initial
  newer.revision += 1
  newer.profiles[0].source = "203.0.113.43 staging"
  try await autosave.schedule(newer)
  try await autosave.flush()
  if cancelAfterCommit { task.cancel() }
  await gate.resume()
  try await task.value
  let snapshot = try #require(await store.state().snapshot)
  #expect(snapshot.applied?.workspace == initial)
  #expect(snapshot.draft == newer)
  newer.revision += 1
  try await autosave.schedule(newer)
  try await autosave.flush()
  #expect(await store.state().snapshot?.draft == newer)
}

@Test(arguments: [
  FixtureApplyEnvironment.Mode.unknownBefore, .unknownAfter, .missingBefore, .missingAfter,
  .badReceipt, .badReadback,
])
private func uncertainCommitRequiresReceiptAndFreshReadback(_ mode: FixtureApplyEnvironment.Mode)
  async throws
{
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let environment = FixtureApplyEnvironment()
  await environment.configure(mode)
  let original = await environment.readSystem()
  do {
    let store = try await fixture.open()
    _ = try await store.saveDraft(applyDraft(), expectedGeneration: 0)
    let coordinator = ApplyCoordinator(store: store, environment: environment)
    let plan = try await coordinator.prepare()
    do {
      try await coordinator.apply(planID: plan.id)
      Issue.record("Expected failure")
    } catch {}
    #expect(await coordinator.state() == .recoveryRequired)
    #expect(await store.state().snapshot?.pendingApply?.transactionID == plan.id)
    #expect(await store.state().snapshot?.applied == nil)
    await #expect(throws: ApplyCoordinatorFailure.recoveryRequired) {
      try await coordinator.prepare()
    }
  }
  let reopened = try await fixture.open()
  let coordinator = ApplyCoordinator(store: reopened, environment: environment)
  if mode == .unknownBefore {
    #expect(try await coordinator.reconcile() == .unconfirmed)
    #expect(await environment.readSystem() == original)
    #expect(await reopened.state().snapshot?.pendingApply == nil)
  } else if mode == .unknownAfter {
    #expect(try await coordinator.reconcile() == .confirmed)
    #expect(await reopened.state().snapshot?.applied != nil)
    #expect(await reopened.state().snapshot?.pendingApply == nil)
  } else {
    do { _ = try await coordinator.reconcile() } catch {}
    #expect(await reopened.state().snapshot?.pendingApply != nil)
    #expect(await reopened.state().snapshot?.applied == nil)
  }
}

@Test(arguments: [FixtureApplyEnvironment.Mode.cacheFailure, .notCommitted])
private func cacheFailureAndProvenNonCommitHaveDifferentResults(
  _ mode: FixtureApplyEnvironment.Mode
)
  async throws
{
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  _ = try await store.saveDraft(applyDraft(), expectedGeneration: 0)
  let environment = FixtureApplyEnvironment()
  await environment.configure(mode)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  if mode == .notCommitted {
    await #expect(throws: ApplyCoordinatorFailure.notCommitted) {
      try await coordinator.apply(planID: plan.id)
    }
    #expect(await store.state().snapshot?.applied == nil)
  } else {
    try await coordinator.apply(planID: plan.id)
    #expect(await store.state().snapshot?.applied?.receipt.cacheFlush == .failed)
  }
  #expect(await store.state().snapshot?.pendingApply == nil)
}

@Test func productionCoordinatorCannotSimulateSuccess() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let coordinator = ApplyCoordinator(store: store)
  await #expect(throws: ApplyCoordinatorFailure.integrationUnavailable) {
    try await coordinator.prepare()
  }
  #expect(await store.state().snapshot?.applied == nil)
}

@Test func foreignChangesOutsideOwnedBlockSurviveButOwnedMutationBlocks() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  _ = try await store.saveDraft(applyDraft(), expectedGeneration: 0)
  let environment = FixtureApplyEnvironment()
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  try await coordinator.apply(planID: plan.id)
  var system = await environment.readSystem()
  system.append(Data("# newer foreign suffix\n".utf8))
  await environment.replace(system)
  let fresh = try await coordinator.prepare()
  #expect(fresh.operation == .noChange)
  #expect(fresh.after == system)
  let changed = Data(
    String(decoding: system, as: UTF8.self).replacingOccurrences(
      of: "203.0.113.42", with: "203.0.113.99"
    ).utf8)
  await environment.replace(changed)
  await #expect(throws: PlanFailure.managedBlockChanged) { try await coordinator.prepare() }
  #expect(await environment.readSystem() == changed)
}

@Test func failedIntentPersistenceNeverStartsCommit() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  do {
    let store = try await fixture.open()
    _ = try await store.saveDraft(applyDraft(), expectedGeneration: 0)
  }
  let store = try await WorkspaceStore.open(
    directory: fixture.directory,
    fault: { point in
      if point == .beforeRename { throw WorkspaceStoreFailure.io(28) }
    })
  let environment = FixtureApplyEnvironment()
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  await #expect(throws: WorkspaceStoreFailure.io(28)) {
    try await coordinator.apply(planID: plan.id)
  }
  #expect(await environment.counts().1 == 0)
  #expect(await store.state().snapshot?.pendingApply == nil)
  #expect(await store.state().snapshot?.applied == nil)
}

@Test(arguments: [WorkspaceWritePoint.beforeRename, .afterRename])
private func appSaveFailureAfterCommitRecoversOnRestart(_ faultPoint: WorkspaceWritePoint)
  async throws
{
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  do {
    let store = try await fixture.open()
    _ = try await store.saveDraft(applyDraft(), expectedGeneration: 0)
  }
  let environment = FixtureApplyEnvironment()
  do {
    let counter = Mutex(0)
    let store = try await WorkspaceStore.open(
      directory: fixture.directory,
      fault: { point in
        if point == faultPoint {
          let count = counter.withLock { value in
            value += 1
            return value
          }
          if count == 2 { throw WorkspaceStoreFailure.io(28) }
        }
      })
    let coordinator = ApplyCoordinator(store: store, environment: environment)
    let plan = try await coordinator.prepare()
    do {
      try await coordinator.apply(planID: plan.id)
      Issue.record("Expected app save failure")
    } catch {}
    #expect(await coordinator.state() == .recoveryRequired)
    #expect(await store.state().snapshot?.applied == nil)
  }
  let store = try await fixture.open()
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  #expect(try await coordinator.reconcile() == .confirmed)
  #expect(await store.state().snapshot?.applied != nil)
  #expect(await store.state().snapshot?.pendingApply == nil)
}

@Test func emptyNoOpNeedsNoAuthorizationAndCreatesNoReceipt() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let environment = FixtureApplyEnvironment()
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let plan = try await coordinator.prepare()
  #expect(plan.operation == .noChange)
  try await coordinator.apply(planID: plan.id)
  #expect(await environment.counts().0 == 0)
  #expect(await environment.counts().1 == 0)
  #expect(await store.state().snapshot?.applied == nil)
  #expect(await store.state().snapshot?.generation == 0)
}

@Test func unownedExistingManagedBlockRequiresExplicitRecovery() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  _ = try await store.saveDraft(applyDraft(), expectedGeneration: 0)
  let environment = FixtureApplyEnvironment()
  let existing = try ApplyPlan.prepare(workspace: applyDraft(), system: Data()).after
  await environment.replace(existing)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  await #expect(throws: PlanFailure.managedBlockChanged) { try await coordinator.prepare() }
  #expect(await environment.counts().0 == 0)
  #expect(await environment.readSystem() == existing)
}

private enum RecoveryScenario: CaseIterable, Sendable {
  case missingJournal, workerActive, unknown, unavailable, invalidReceipt, notCommitted, committed,
    retired, invalidRetirement

  var evidence: ApplyRecoveryEvidence {
    switch self {
    case .missingJournal: .missingJournal
    case .workerActive: .workerActive
    case .unknown: .unknown
    case .unavailable: .unavailable
    case .invalidReceipt: .invalidReceipt
    case .notCommitted: .notCommitted
    case .committed: .verifiedReceipt
    case .retired: .retired
    case .invalidRetirement: .invalidRetirement
    }
  }
}

private actor RecoveryEnvironment: ApplyEnvironment {
  var bytes: Data
  let pending: PendingApply
  let scenario: RecoveryScenario
  let gate: ApplyGate?
  let failedRead: Int?
  var reads = 0
  var outcomes = 0

  init(
    pending: PendingApply, bytes: Data, scenario: RecoveryScenario,
    gate: ApplyGate? = nil, failedRead: Int? = nil
  ) {
    self.pending = pending
    self.bytes = bytes
    self.scenario = scenario
    self.gate = gate
    self.failedRead = failedRead
  }

  func replace(_ bytes: Data) { self.bytes = bytes }
  func readSystem() throws -> Data {
    reads += 1
    if reads == failedRead { throw ApplyCoordinatorFailure.unverifiedResult }
    return bytes
  }
  func authorize(_ planID: UUID) throws { throw ApplyCoordinatorFailure.integrationUnavailable }
  func commit(_ plan: ApplyPlan) throws -> ApplyReceipt {
    throw ApplyCoordinatorFailure.integrationUnavailable
  }
  func outcome(for transactionID: UUID) async throws -> ApplyTransactionOutcome {
    outcomes += 1
    await gate?.pause()
    switch scenario {
    case .missingJournal: return .missingJournal
    case .workerActive: return .workerActive
    case .unknown: return .unknown
    case .unavailable: throw ApplyCoordinatorFailure.integrationUnavailable
    case .notCommitted: return .notCommitted
    case .retired: return .retired(try ApplyRetirement(pending: pending))
    case .invalidRetirement:
      let workspace = applyDraft()
      let plan = try ApplyPlan.prepare(workspace: workspace, system: Data("# different".utf8))
      return .retired(try ApplyRetirement(pending: PendingApply(workspace: workspace, plan: plan)))
    case .committed, .invalidReceipt:
      return .committed(
        ApplyReceipt(
          transactionID: scenario == .invalidReceipt ? UUID() : transactionID,
          beforeDigest: pending.beforeDigest, afterDigest: pending.afterDigest,
          backupID: UUID(), readback: .verified, cacheFlush: .notAttempted))
    }
  }
}

private func seedRecovery(_ store: WorkspaceStore) async throws -> (PendingApply, ApplyPlan) {
  let workspace = applyDraft()
  let saved = try await store.saveDraft(workspace, expectedGeneration: 0)
  let plan = try ApplyPlan.prepare(workspace: workspace, system: Data("# before\n".utf8))
  let pending = try PendingApply(workspace: workspace, plan: plan)
  try await store.beginApply(pending, expectedGeneration: saved.generation)
  // Simulates a restarted app, with a durable intent and no in-process commit in flight.
  await store.releaseApply(pending.transactionID)
  return (pending, plan)
}

@Test(arguments: RecoveryScenario.allCases, [PendingApplyFileState.before, .after, .other])
private func recoveryEvidenceMatrixPreservesOrphansAndNeverInfersReceipts(
  _ scenario: RecoveryScenario, _ fileState: PendingApplyFileState
) async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let (pending, plan) = try await seedRecovery(store)
  let bytes =
    fileState == .before ? plan.before : fileState == .after ? plan.after : Data("# other".utf8)
  let environment = RecoveryEnvironment(pending: pending, bytes: bytes, scenario: scenario)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let snapshot = await store.state().snapshot
  let file = fixture.directory.appendingPathComponent("workspace.json")
  let savedBytes = try Data(contentsOf: file)
  let resolved =
    (scenario == .committed && fileState == .after)
    || ((scenario == .notCommitted || scenario == .retired) && fileState == .before)
  if scenario == .unavailable || scenario == .invalidReceipt || scenario == .invalidRetirement {
    await #expect(throws: (any Error).self) { try await coordinator.reconcile() }
  } else {
    #expect(
      try await coordinator.reconcile()
        == (resolved ? (scenario == .committed ? .confirmed : .unconfirmed) : .recoveryRequired))
  }
  let assessment = try #require(await coordinator.recoveryAssessment())
  #expect(assessment.transactionID == pending.transactionID)
  #expect(assessment.evidence == scenario.evidence)
  #expect(assessment.fileState == fileState)
  #expect(try await environment.readSystem() == bytes)
  #expect(await store.isApplyInFlight() == false)
  if !resolved {
    #expect(await store.state().snapshot == snapshot)
    #expect(try Data(contentsOf: file) == savedBytes)
    #expect(await coordinator.state() == .recoveryRequired)
    // Rechecking is safe, never a dismissal of the orphaned app intent.
    do { _ = try await coordinator.reconcile() } catch {}
    #expect(await store.state().snapshot == snapshot)
    await #expect(throws: ApplyCoordinatorFailure.recoveryRequired) {
      try await coordinator.prepare()
    }
  } else {
    #expect(await store.state().snapshot?.pendingApply == nil)
    #expect((await store.state().snapshot?.applied != nil) == (scenario == .committed))
  }
}

@Test(arguments: [1, 2])
private func recoveryReadFailurePreservesIntentAndReleasesLease(_ failedRead: Int) async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let (pending, plan) = try await seedRecovery(store)
  let environment = RecoveryEnvironment(
    pending: pending, bytes: plan.after, scenario: .committed, failedRead: failedRead)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  await #expect(throws: ApplyCoordinatorFailure.unverifiedResult) {
    try await coordinator.reconcile()
  }
  let assessment = try #require(await coordinator.recoveryAssessment())
  #expect(assessment.fileState == .unreadable)
  #expect(assessment.evidence == (failedRead == 1 ? .unavailable : .verifiedReceipt))
  #expect(await store.state().snapshot?.pendingApply == pending)
  #expect(await store.isApplyInFlight() == false)
  #expect(try await coordinator.reconcile() == .confirmed)
}

@Test(arguments: [false, true])
private func recoveryLeaseRejectsOtherCoordinatorsAndRechecksAfterAwait(_ externalChange: Bool)
  async throws
{
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let (pending, plan) = try await seedRecovery(store)
  let gate = ApplyGate()
  let environment = RecoveryEnvironment(
    pending: pending, bytes: plan.before, scenario: .committed, gate: gate)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let running = Task { try await coordinator.reconcile() }
  await gate.waitForArrival()
  let other = ApplyCoordinator(store: store, environment: environment)
  await #expect(throws: ApplyCoordinatorFailure.busy) { try await other.reconcile() }
  await #expect(throws: ApplyCoordinatorFailure.recoveryRequired) { try await other.prepare() }
  #expect(await environment.outcomes == 1)
  let snapshot = try #require(await store.state().snapshot)
  var newer = snapshot.draft
  newer.revision += 1
  newer.profiles[0].source = "203.0.113.43 newer"
  _ = try await store.saveDraft(newer, expectedGeneration: snapshot.generation)
  await environment.replace(externalChange ? Data("# newer external bytes".utf8) : plan.after)
  await gate.resume()
  #expect(try await running.value == (externalChange ? .recoveryRequired : .confirmed))
  #expect(await coordinator.recoveryAssessment()?.fileState == (externalChange ? .other : .after))
  #expect(await store.state().snapshot?.draft == newer)
  #expect((await store.state().snapshot?.pendingApply != nil) == externalChange)
  #expect(
    await store.state().snapshot?.applied?.workspace == (externalChange ? nil : pending.workspace))
  #expect(await store.isApplyInFlight() == false)
}

@Test private func cancelledRecoveryKeepsIntentAndAllowsNewAttempt() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let (pending, plan) = try await seedRecovery(store)
  let gate = ApplyGate()
  let environment = RecoveryEnvironment(
    pending: pending, bytes: plan.after, scenario: .committed, gate: gate)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let running = Task { try await coordinator.reconcile() }
  await gate.waitForArrival()
  running.cancel()
  await gate.resume()
  await #expect(throws: CancellationError.self) { try await running.value }
  #expect(await coordinator.state() == .recoveryRequired)
  #expect(await store.state().snapshot?.pendingApply == pending)
  #expect(await store.state().snapshot?.applied == nil)
  #expect(await store.isApplyInFlight() == false)
  // The gate is only needed for the interrupted attempt.
  let retry = RecoveryEnvironment(pending: pending, bytes: plan.after, scenario: .committed)
  #expect(try await ApplyCoordinator(store: store, environment: retry).reconcile() == .confirmed)
}

private func seedOrphanWithHistory(_ fixture: ApplyFixture) async throws -> (
  WorkspaceSnapshot, ApplyPlan
) {
  let store = try await fixture.open()
  let environment = FixtureApplyEnvironment()
  _ = try await store.saveDraft(applyDraft(), expectedGeneration: 0)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let original = try await coordinator.prepare()
  try await coordinator.apply(planID: original.id)
  let saved = try #require(await store.state().snapshot)
  var desired = saved.draft
  desired.revision += 1
  desired.profiles[0].source = "203.0.113.43 staging"
  _ = try await store.saveDraft(desired, expectedGeneration: saved.generation)
  let next = try await coordinator.prepare()
  let fresh = try #require(await store.state().snapshot)
  try await store.beginApply(
    PendingApply(workspace: desired, plan: next), expectedGeneration: fresh.generation)
  await store.releaseApply(next.id)
  let pending = try #require(await store.state().snapshot)
  var newer = desired
  newer.revision += 1
  newer.profiles[0].name = "Newer draft"
  let snapshot = try await store.saveDraft(newer, expectedGeneration: pending.generation)
  return (snapshot, next)
}

@Test(arguments: [PendingApplyFileState.before, .after, .other])
private func orphanAfterRestartPreservesEarlierReceiptAndNewerDraft(_ state: PendingApplyFileState)
  async throws
{
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let (snapshot, plan) = try await seedOrphanWithHistory(fixture)
  let pending = try #require(snapshot.pendingApply)
  let previous = try #require(snapshot.applied)
  #expect(previous.receipt.transactionID != pending.transactionID)
  #expect(previous.workspace != pending.workspace)
  #expect(snapshot.draft != pending.workspace)
  let store = try await fixture.open()
  let bytes =
    state == .before ? plan.before : state == .after ? plan.after : Data("# external".utf8)
  let environment = RecoveryEnvironment(pending: pending, bytes: bytes, scenario: .missingJournal)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  #expect(await coordinator.state() == .recoveryRequired)
  #expect(try await coordinator.reconcile() == .recoveryRequired)
  #expect(await coordinator.recoveryAssessment()?.evidence == .missingJournal)
  #expect(await coordinator.recoveryAssessment()?.fileState == state)
  #expect(await store.state().snapshot == snapshot)
  let persisted = try JSONDecoder().decode(
    WorkspaceSnapshot.self,
    from: Data(contentsOf: fixture.directory.appendingPathComponent("workspace.json")))
  #expect(persisted == snapshot)
  #expect(persisted.applied == previous)
}

@Test private func unavailableProductionRecoveryPreservesPendingIntent() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let (pending, _) = try await seedRecovery(store)
  let snapshot = await store.state().snapshot
  let coordinator = ApplyCoordinator(store: store)
  await #expect(throws: ApplyCoordinatorFailure.integrationUnavailable) {
    try await coordinator.reconcile()
  }
  #expect(await coordinator.recoveryAssessment()?.fileState == .unreadable)
  #expect(await coordinator.recoveryAssessment()?.evidence == .unavailable)
  #expect(await coordinator.recoveryAssessment()?.transactionID == pending.transactionID)
  #expect(await coordinator.state() == .recoveryRequired)
  #expect(await store.state().snapshot == snapshot)
  #expect(await store.isApplyInFlight() == false)
}

@Test func retiredIntentPreservesEarlierReceiptAndNewerDraft() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let (snapshot, plan) = try await seedOrphanWithHistory(fixture)
  let store = try await fixture.open()
  let pending = try #require(snapshot.pendingApply)
  let environment = RecoveryEnvironment(pending: pending, bytes: plan.before, scenario: .retired)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  #expect(try await coordinator.reconcile() == .unconfirmed)
  let resolved = try #require(await store.state().snapshot)
  #expect(resolved.pendingApply == nil)
  #expect(resolved.applied == snapshot.applied)
  #expect(resolved.draft == snapshot.draft)
}

@Test func productionRetirementRemainsUnavailableAndKeepsIntent() async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let (pending, _) = try await seedRecovery(store)
  let before = await store.state().snapshot
  let coordinator = ApplyCoordinator(store: store)
  await #expect(throws: ApplyCoordinatorFailure.integrationUnavailable) {
    try await coordinator.retireOrphan(transactionID: pending.transactionID)
  }
  #expect(await store.state().snapshot == before)
  #expect(await store.isApplyInFlight() == false)
  #expect(await coordinator.state() == .recoveryRequired)
}

private actor RetirementEnvironment: ApplyEnvironment {
  let pending: PendingApply
  let gate: ApplyGate
  var bytes: Data
  var retired = false
  var finalReadFails = false
  init(pending: PendingApply, bytes: Data, gate: ApplyGate) {
    self.pending = pending
    self.bytes = bytes
    self.gate = gate
  }
  func replace(_ bytes: Data) { self.bytes = bytes }
  func failRead() { finalReadFails = true }
  func readSystem() throws -> Data {
    if finalReadFails { throw ApplyCoordinatorFailure.unverifiedResult }
    return bytes
  }
  func authorize(_ planID: UUID) throws { throw ApplyCoordinatorFailure.integrationUnavailable }
  func commit(_ plan: ApplyPlan) throws -> ApplyReceipt {
    throw ApplyCoordinatorFailure.integrationUnavailable
  }
  func retireOrphan(_ retirement: ApplyRetirement) async throws -> ApplyRetirement {
    try retirement.validate(pending: pending)
    retired = true
    await gate.pause()
    return retirement
  }
  func outcome(for transactionID: UUID) throws -> ApplyTransactionOutcome {
    retired ? .retired(try ApplyRetirement(pending: pending)) : .missingJournal
  }
}

@Test(arguments: ["success", "external", "readFailure", "cancel"])
private func retirementLeaseAndFinalReadPreserveEditsAndIntent(_ change: String) async throws {
  let fixture = try ApplyFixture()
  defer { fixture.cleanup() }
  let store = try await fixture.open()
  let (pending, plan) = try await seedRecovery(store)
  let gate = ApplyGate()
  let environment = RetirementEnvironment(pending: pending, bytes: plan.before, gate: gate)
  let coordinator = ApplyCoordinator(store: store, environment: environment)
  let other = ApplyCoordinator(store: store, environment: environment)
  await #expect(throws: ApplyCoordinatorFailure.stalePlan) {
    try await coordinator.retireOrphan(transactionID: UUID())
  }
  let operation = Task { try await coordinator.retireOrphan(transactionID: pending.transactionID) }
  await gate.waitForArrival()
  await #expect(throws: ApplyCoordinatorFailure.busy) {
    try await other.retireOrphan(transactionID: pending.transactionID)
  }
  await #expect(throws: ApplyCoordinatorFailure.busy) { try await other.reconcile() }
  let snapshot = try #require(await store.state().snapshot)
  var newer = snapshot.draft
  newer.revision += 1
  newer.profiles[0].name = "Edited during retirement"
  _ = try await store.saveDraft(newer, expectedGeneration: snapshot.generation)
  switch change {
  case "external": await environment.replace(plan.after)
  case "readFailure": await environment.failRead()
  case "cancel": operation.cancel()
  default: break
  }
  await gate.resume()
  if change == "readFailure" || change == "cancel" {
    await #expect(throws: (any Error).self) { try await operation.value }
  } else {
    #expect(try await operation.value == (change == "external" ? .recoveryRequired : .unconfirmed))
  }
  let after = try #require(await store.state().snapshot)
  #expect(after.draft == newer)
  #expect(after.applied == nil)
  #expect((after.pendingApply == nil) == (change == "success"))
  #expect(await store.isApplyInFlight() == false)
  if change != "success" { #expect(await coordinator.state() == .recoveryRequired) }
}
