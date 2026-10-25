import Darwin
import Foundation
import HostsCore
import Testing

@testable import HostsServices

private struct PrivateWorkspace {
  let parent: URL
  let directory: URL
  init() throws {
    parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "machosts-store-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    directory = parent.appendingPathComponent("workspace", isDirectory: true)
  }
  func cleanup() {
    do { try FileManager.default.removeItem(at: parent) } catch {
      Issue.record("Private fixture cleanup failed: \(error)")
    }
  }
  func file(_ name: String = "workspace.json") -> URL { directory.appendingPathComponent(name) }
  func put(_ data: Data, name: String = "workspace.json") throws {
    try data.write(to: file(name))
    guard chmod(file(name).path, 0o600) == 0 else { throw WorkspaceStoreFailure.io(errno) }
  }
}

private func draft(_ revision: UInt64, source: String = "203.0.113.1 staging") -> Workspace {
  Workspace(
    revision: revision, profiles: [Profile(name: "Staging", source: source, isEnabled: true)])
}

@Test func restartRoundtripAndReceiptSeparation() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let desired = draft(1)
  let plan = try ApplyPlan.prepare(workspace: desired, system: Data("# foreign".utf8))
  let receipt = ApplyReceipt(
    transactionID: plan.id, beforeDigest: plan.expectedSystemDigest,
    afterDigest: plan.resultingSystemDigest, backupID: UUID(), readback: .verified,
    cacheFlush: .failed)
  let applied = try AppliedWorkspaceSnapshot(workspace: desired, plan: plan, receipt: receipt)
  let saved: WorkspaceSnapshot
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    _ = try await store.saveDraft(desired, expectedGeneration: 0)
    _ = try await store.recordApplied(applied, expectedGeneration: 1)
    var changed = desired
    changed.revision += 1
    changed.profiles[0].source = "203.0.113.2 staging"
    saved = try await store.saveDraft(changed, expectedGeneration: 2)
    #expect(saved.applied?.workspace == desired)
    #expect(saved.draft == changed)
    #expect(saved.applied?.receipt.cacheFlush == .failed)
  }
  let reopened = try await WorkspaceStore.open(directory: fixture.directory)
  let state = await reopened.state()
  #expect(state.snapshot == saved)
  #expect(state.readOnlyReason == nil)
  #expect(state.recoveryCandidate?.generation == 2)
  let mode =
    try FileManager.default.attributesOfItem(atPath: fixture.file().path)[.posixPermissions]
    as? NSNumber
  #expect(mode?.intValue == 0o600)
}

@Test func rejectUnverifiedOrMismatchedAppliedSnapshots() throws {
  let desired = draft(1)
  let plan = try ApplyPlan.prepare(workspace: desired, system: Data())
  let wrongReceipt = ApplyReceipt(
    transactionID: plan.id, beforeDigest: plan.expectedSystemDigest,
    afterDigest: plan.resultingSystemDigest, backupID: UUID(), readback: .mismatch,
    cacheFlush: .succeeded)
  #expect(throws: AppliedSnapshotFailure.unverifiedReceipt) {
    try AppliedWorkspaceSnapshot(workspace: desired, plan: plan, receipt: wrongReceipt)
  }
  let wrongPlanReceipt = ApplyReceipt(
    transactionID: UUID(), beforeDigest: plan.expectedSystemDigest,
    afterDigest: plan.resultingSystemDigest, backupID: UUID(), readback: .verified,
    cacheFlush: .notAttempted)
  #expect(throws: AppliedSnapshotFailure.planMismatch) {
    try AppliedWorkspaceSnapshot(workspace: desired, plan: plan, receipt: wrongPlanReceipt)
  }
}

@Test(arguments: [
  Data("{\"schemaVersion\":99}".utf8), Data("{\"schemaVersion\":1,".utf8),
  Data("{\"schemaVersion\":0}".utf8),
])
func corruptAndUnknownSnapshotsRemainUntouched(_ data: Data) async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  try FileManager.default.createDirectory(
    at: fixture.directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  try fixture.put(data)
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let state = await store.state()
  #expect(state.snapshot == nil)
  #expect(state.readOnlyReason != nil)
  await #expect(throws: WorkspaceStoreFailure.readOnly) {
    try await store.saveDraft(draft(1), expectedGeneration: 0)
  }
  #expect(try Data(contentsOf: fixture.file()) == data)
}

@Test func previousSnapshotIsExplicitRecoveryCandidate() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let first = draft(1)
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    _ = try await store.saveDraft(first, expectedGeneration: 0)
    _ = try await store.saveDraft(draft(2), expectedGeneration: 1)
  }
  let broken = Data("broken".utf8)
  try fixture.put(broken)
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let state = await store.state()
  #expect(state.snapshot == nil && state.readOnlyReason == .corruptSnapshot)
  #expect(state.recoveryCandidate?.draft == first)
  #expect(try Data(contentsOf: fixture.file()) == broken)
}

@Test func missingCurrentWithBrokenBackupNeverBecomesEmptyWorkspace() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  try FileManager.default.createDirectory(
    at: fixture.directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  try fixture.put(Data("broken".utf8), name: "workspace.previous.json")
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let state = await store.state()
  #expect(state.snapshot == nil && state.readOnlyReason == .corruptSnapshot)
}

@Test func secondWriterAndParallelRevisionsAreRejected() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  await #expect(throws: WorkspaceStoreFailure.alreadyOpen) {
    try await WorkspaceStore.open(directory: fixture.directory)
  }
  async let a: Result<WorkspaceSnapshot, any Error> = saveResult(store, workspace: draft(1))
  async let b: Result<WorkspaceSnapshot, any Error> = saveResult(store, workspace: draft(2))
  let results = await [a, b]
  #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
  #expect(
    results.filter {
      if case .failure(let error) = $0 {
        (error as? WorkspaceStoreFailure) == .staleGeneration
      } else {
        false
      }
    }.count == 1)
}

private func saveResult(_ store: WorkspaceStore, workspace: Workspace) async -> Result<
  WorkspaceSnapshot, any Error
> {
  do { return .success(try await store.saveDraft(workspace, expectedGeneration: 0)) } catch {
    return .failure(error)
  }
}

@Test(arguments: [WorkspaceWritePoint.beforeWrite, .beforeRename, .afterRename])
func interruptionPreservesConfirmedData(_ point: WorkspaceWritePoint) async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let first = draft(1)
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    _ = try await store.saveDraft(first, expectedGeneration: 0)
  }
  let second = draft(2)
  do {
    let store = try await WorkspaceStore.open(
      directory: fixture.directory,
      fault: { current in
        if current == point { throw WorkspaceStoreFailure.io(ENOSPC) }
      })
    let expected: WorkspaceStoreFailure =
      point == .afterRename ? .commitOutcomeUnknown : .io(ENOSPC)
    await #expect(throws: expected) { try await store.saveDraft(second, expectedGeneration: 1) }
    let state = await store.state()
    #expect(state.snapshot?.draft == first)
    #expect(state.readOnlyReason == (point == .afterRename ? .interruptedCommit : nil))
  }
  let reopened = try await WorkspaceStore.open(directory: fixture.directory)
  let state = await reopened.state()
  #expect(state.snapshot?.draft == (point == .afterRename ? second : first))
  #expect(state.recoveryCandidate?.draft == first)
}

@Test func permissionFailureDoesNotReportSaved() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(
    directory: fixture.directory,
    fault: { point in
      if point == .beforeRename { throw WorkspaceStoreFailure.io(EACCES) }
    })
  await #expect(throws: WorkspaceStoreFailure.io(EACCES)) {
    try await store.saveDraft(draft(1), expectedGeneration: 0)
  }
  #expect(await store.state().snapshot?.generation == 0)
  #expect(!FileManager.default.fileExists(atPath: fixture.file().path))
}

@Test func externalMutationPreventsOverwrite() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  _ = try await store.saveDraft(draft(1), expectedGeneration: 0)
  let foreign = Data("externally changed".utf8)
  try fixture.put(foreign)
  await #expect(throws: WorkspaceStoreFailure.externalChange) {
    try await store.saveDraft(draft(2), expectedGeneration: 1)
  }
  #expect(try Data(contentsOf: fixture.file()) == foreign)
  #expect(await store.state().readOnlyReason != nil)
}

@Test func symlinkHardlinkAndUnsafePermissionsAreRejected() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  try FileManager.default.createDirectory(
    at: fixture.directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let target = fixture.parent.appendingPathComponent("private-fixture")
  try Data("safe".utf8).write(to: target)
  guard chmod(target.path, 0o600) == 0 else { throw WorkspaceStoreFailure.io(errno) }
  try FileManager.default.createSymbolicLink(at: fixture.file(), withDestinationURL: target)
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    #expect(await store.state().readOnlyReason == .unsafeOrUnreadableFile)
  }
  try FileManager.default.removeItem(at: fixture.file())
  try FileManager.default.linkItem(at: target, to: fixture.file())
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    #expect(await store.state().readOnlyReason == .unsafeOrUnreadableFile)
  }
  #expect(try Data(contentsOf: target) == Data("safe".utf8))
  guard chmod(fixture.directory.path, 0o777) == 0 else { throw WorkspaceStoreFailure.io(errno) }
  await #expect(throws: WorkspaceStoreFailure.unsafeFile) {
    try await WorkspaceStore.open(directory: fixture.directory)
  }
}

@Test func autosaveCoalescesAndFlushesLatestRevision() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let autosave = try await WorkspaceAutosave.open(store: store, delay: .seconds(60))
  for revision in 1...25 { try await autosave.schedule(draft(UInt64(revision))) }
  #expect(await store.state().snapshot?.generation == 0)
  async let a: Void = autosave.flush()
  async let b: Void = autosave.flush()
  _ = try await (a, b)
  #expect(await store.state().snapshot?.draft.revision == 25)
  #expect(await autosave.state().savedGeneration == 1)
  #expect(await autosave.state().pendingRevision == nil)
}

@Test func autosaveFailureRetainsDirtyDraft() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(
    directory: fixture.directory,
    fault: { point in
      if point == .beforeWrite { throw WorkspaceStoreFailure.io(ENOSPC) }
    })
  let autosave = try await WorkspaceAutosave.open(store: store, delay: .seconds(60))
  try await autosave.schedule(draft(1))
  await #expect(throws: WorkspaceStoreFailure.io(ENOSPC)) { try await autosave.flush() }
  #expect(await autosave.state().pendingRevision == 1)
  #expect(await autosave.state().lastFailure != nil)
  #expect(await store.state().snapshot?.generation == 0)
}

@Test func explicitRecoveryArchivesOriginalAndNeverDowngradesUnknownSchema() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let first = draft(1)
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    _ = try await store.saveDraft(first, expectedGeneration: 0)
    _ = try await store.saveDraft(draft(2), expectedGeneration: 1)
  }
  let broken = Data("{truncated".utf8)
  try fixture.put(broken)
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    await #expect(throws: WorkspaceStoreFailure.externalChange) {
      try await store.recoverPrevious(expectedCurrentDigest: ContentDigest(Data()))
    }
    let recovered = try await store.recoverPrevious(expectedCurrentDigest: ContentDigest(broken))
    #expect(recovered.draft == first)
    #expect(await store.state().readOnlyReason == nil)
    let archives = try FileManager.default.contentsOfDirectory(
      at: fixture.directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("workspace.recovery-") }
    #expect(archives.count == 1)
    #expect(try Data(contentsOf: #require(archives.first)) == broken)
  }
  let newer = Data("{\"schemaVersion\":99}".utf8)
  try fixture.put(newer)
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  await #expect(throws: WorkspaceStoreFailure.readOnly) {
    try await store.recoverPrevious(expectedCurrentDigest: ContentDigest(newer))
  }
  #expect(try Data(contentsOf: fixture.file()) == newer)
}

@Test func autosaveTimerActuallySavesWithoutExplicitFlush() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let autosave = try await WorkspaceAutosave.open(store: store, delay: .milliseconds(10))
  try await autosave.schedule(draft(1))
  let deadline = ContinuousClock.now + .seconds(5)
  while await store.state().snapshot?.generation == 0 && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(await store.state().snapshot?.draft.revision == 1)
  try await autosave.flush()
  #expect(await autosave.state().pendingRevision == nil)
}

@Test func storeEnforcesRevisionAndRejectsOversizedFiles() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    _ = try await store.saveDraft(draft(1), expectedGeneration: 0)
    await #expect(throws: WorkspaceStoreFailure.staleRevision) {
      try await store.saveDraft(draft(1), expectedGeneration: 1)
    }
  }
  try fixture.put(Data(repeating: 32, count: HostsLimits.workspaceBytes + 1))
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  #expect(await store.state().readOnlyReason == .unsafeOrUnreadableFile)
  await #expect(throws: WorkspaceStoreFailure.readOnly) {
    try await store.saveDraft(draft(2), expectedGeneration: 1)
  }
}

@Test func schemaOneMigrationArchivesExactBytesAndPreservesAppliedState() async throws {
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  try FileManager.default.createDirectory(
    at: fixture.directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let desired = draft(4)
  let plan = try ApplyPlan.prepare(workspace: desired, system: Data())
  let receipt = ApplyReceipt(
    transactionID: plan.id, beforeDigest: plan.expectedSystemDigest,
    afterDigest: plan.resultingSystemDigest, backupID: UUID(), readback: .verified,
    cacheFlush: .failed)
  let applied = try AppliedWorkspaceSnapshot(workspace: desired, plan: plan, receipt: receipt)
  let current = WorkspaceSnapshot(generation: 7, draft: desired, applied: applied)
  var object = try #require(JSONSerialization.jsonObject(with: current.encoded()) as? [String: Any])
  object["schemaVersion"] = 1
  var oldApplied = try #require(object["applied"] as? [String: Any])
  oldApplied.removeValue(forKey: "managedDigest")
  object["applied"] = oldApplied
  let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  try fixture.put(legacy)
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    let migrated = try #require(await store.state().snapshot)
    #expect(migrated.schemaVersion == 2 && migrated.generation == 8)
    #expect(migrated.draft == desired)
    #expect(migrated.applied?.receipt == receipt)
    #expect(migrated.pendingApply == nil)
    let archives = try FileManager.default.contentsOfDirectory(
      at: fixture.directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("workspace.recovery-") }
    #expect(archives.count == 1)
    #expect(try Data(contentsOf: #require(archives.first)) == legacy)
  }
  let reopened = try await WorkspaceStore.open(directory: fixture.directory)
  #expect(await reopened.state().snapshot?.generation == 8)
}

@Test(arguments: [WorkspaceWritePoint.beforeRename, .afterRename])
func schemaMigrationInterruptionNeverResetsWorkspace(_ faultPoint: WorkspaceWritePoint) async throws
{
  let fixture = try PrivateWorkspace()
  defer { fixture.cleanup() }
  try FileManager.default.createDirectory(
    at: fixture.directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let desired = draft(3)
  var object = try #require(
    JSONSerialization.jsonObject(with: WorkspaceSnapshot(generation: 4, draft: desired).encoded())
      as? [String: Any])
  object["schemaVersion"] = 1
  let legacy = try JSONSerialization.data(withJSONObject: object)
  try fixture.put(legacy)
  do {
    let store = try await WorkspaceStore.open(
      directory: fixture.directory,
      fault: { point in if point == faultPoint { throw WorkspaceStoreFailure.io(ENOSPC) } })
    #expect(await store.state().readOnlyReason != nil)
    #expect(await store.state().snapshot == nil)
    let archives = try FileManager.default.contentsOfDirectory(
      at: fixture.directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("workspace.recovery-") }
    #expect(try Data(contentsOf: #require(archives.first)) == legacy)
  }
  let reopened = try await WorkspaceStore.open(directory: fixture.directory)
  #expect(await reopened.state().snapshot?.draft == desired)
  #expect(await reopened.state().snapshot?.generation == 5)
}
