import Foundation
import HostsCore
import Testing

@testable import HostsServices

@MainActor
private func waitForObservation(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(3)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      throw ObservationTestFailure.deadline
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private enum ObservationTestFailure: Error { case deadline }

private struct ObservationFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "machosts-observation-model-" + UUID().uuidString)
  let before = Data("# private foreign bytes\n".utf8)
  let workspace: Workspace
  let plan: ApplyPlan
  let applied: AppliedWorkspaceSnapshot
  var file: URL { directory.appendingPathComponent("hosts") }

  init() throws {
    let draft = Workspace(
      revision: 1,
      profiles: [
        Profile(name: "Fixture", source: "192.0.2.1 fixture.example\n", isEnabled: true)
      ])
    workspace = draft
    plan = try ApplyPlan.prepare(workspace: draft, system: before)
    applied = try AppliedWorkspaceSnapshot(
      workspace: draft, plan: plan,
      receipt: ApplyReceipt(
        transactionID: plan.id, beforeDigest: plan.expectedSystemDigest,
        afterDigest: plan.resultingSystemDigest, backupID: UUID(),
        readback: .verified, cacheFlush: .notAttempted))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  func cleanup() {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Observation fixture cleanup failed")
    }
  }

  func load(
    applied: AppliedWorkspaceSnapshot? = nil, pending: PendingApply? = nil,
    reason: WorkspaceRecoveryReason? = nil
  ) -> WorkspaceLoad {
    .init(
      snapshot: WorkspaceSnapshot(draft: workspace, applied: applied, pendingApply: pending),
      readOnlyReason: reason, recoveryCandidate: nil)
  }
}

@Test @MainActor func observationModelRecomputesOnReceiptChangesWithoutFileEvents() async throws {
  let fixture = try ObservationFixture()
  defer { fixture.cleanup() }
  try fixture.plan.after.write(to: fixture.file)
  let monitor = SystemFileMonitor(directory: fixture.directory)
  let model = SystemObservationModel(monitor: monitor)
  let task = Task { await model.run() }
  defer { task.cancel() }
  try await waitForObservation { model.observation != nil }
  #expect(model.status == .unconfirmed)
  model.updateWorkspace(fixture.load())
  #expect(model.status == .unconfirmed)
  model.updateWorkspace(fixture.load(applied: fixture.applied))
  #expect(model.status == .confirmed)
  model.updateWorkspace(fixture.load(applied: fixture.applied, reason: .externalChange))
  #expect(model.status == .unconfirmed)
  model.updateWorkspace(nil)
  #expect(model.workspaceUnavailable)
  #expect(model.status == .unconfirmed)
  model.updateWorkspace(fixture.load(applied: fixture.applied))
  #expect(model.status == .confirmed)
  task.cancel()
  await task.value
  #expect(!model.isMonitoring)
  #expect(model.observation == nil)
  #expect(model.status == .unconfirmed)
}

@Test @MainActor func observationModelTracksExternalChangesErrorsAndPendingIntent() async throws {
  let fixture = try ObservationFixture()
  defer { fixture.cleanup() }
  try fixture.plan.after.write(to: fixture.file)
  let model = SystemObservationModel(monitor: SystemFileMonitor(directory: fixture.directory))
  model.updateWorkspace(fixture.load(applied: fixture.applied))
  let task = Task { await model.run() }
  defer { task.cancel() }
  try await waitForObservation { model.status == .confirmed }
  try fixture.before.write(to: fixture.file, options: .atomic)
  try await waitForObservation { model.status == .externalChange }
  let pending = try PendingApply(workspace: fixture.workspace, plan: fixture.plan)
  let store = try await WorkspaceStore.open(
    directory: fixture.directory.appendingPathComponent("workspace"))
  let saved = try await store.saveDraft(fixture.workspace, expectedGeneration: 0)
  let recorded = try await store.recordApplied(
    fixture.applied, expectedGeneration: saved.generation)
  try await store.beginApply(pending, expectedGeneration: recorded.generation)
  let persisted = await store.state()
  let workspaceFile = fixture.directory.appendingPathComponent("workspace/workspace.json")
  let persistedBytes = try Data(contentsOf: workspaceFile)
  model.updateWorkspace(persisted)
  #expect(model.status == .recoveryRequired)
  #expect(model.pendingFileState == .before)
  try FileManager.default.removeItem(at: fixture.file)
  try await waitForObservation { model.observation == .unreadable(.unavailable) }
  #expect(model.status == .recoveryRequired)
  #expect(model.pendingFileState == .unreadable)
  try fixture.plan.after.write(to: fixture.file)
  try await waitForObservation {
    model.observation == .readable(fixture.plan.resultingSystemDigest)
  }
  #expect(model.status == .recoveryRequired)
  #expect(model.pendingFileState == .after)
  try Data("# a third state\n".utf8).write(to: fixture.file, options: .atomic)
  try await waitForObservation { model.pendingFileState == .other }
  #expect(model.status == .recoveryRequired)
  try fixture.plan.after.write(to: fixture.file, options: .atomic)
  try await waitForObservation { model.pendingFileState == .after }
  model.updateWorkspace(fixture.load(applied: fixture.applied))
  #expect(model.status == .confirmed)
  #expect(model.pendingFileState == nil)
  // All observations leave persisted intent and snapshot decisions to the coordinator.
  #expect(await store.state().snapshot == persisted.snapshot)
  #expect(try Data(contentsOf: workspaceFile) == persistedBytes)
  model.updateWorkspace(persisted)
  task.cancel()
  await task.value
  #expect(model.status == .recoveryRequired)
  #expect(model.pendingFileState == .unreadable)
}

@Test @MainActor func observationModelRestartsAfterWatchFailureAndReplacesOldConsumer() async throws
{
  let fixture = try ObservationFixture()
  defer { fixture.cleanup() }
  try fixture.plan.after.write(to: fixture.file)
  let model = SystemObservationModel(monitor: SystemFileMonitor(directory: fixture.directory))
  model.updateWorkspace(fixture.load(applied: fixture.applied))
  let first = Task { await model.run() }
  defer { first.cancel() }
  try await waitForObservation { model.status == .confirmed }
  let moved = fixture.directory.appendingPathExtension("moved")
  try FileManager.default.moveItem(at: fixture.directory, to: moved)
  try await waitForObservation { model.observation == .unreadable(.watchUnavailable) }
  #expect(model.status == .unconfirmed)
  try FileManager.default.moveItem(at: moved, to: fixture.directory)
  await model.refresh()
  #expect(model.observation == .unreadable(.watchUnavailable))
  let second = Task { await model.run() }
  defer { second.cancel() }
  await first.value
  try await waitForObservation { model.status == .confirmed }
  #expect(model.isMonitoring)
  first.cancel()
  try fixture.before.write(to: fixture.file, options: .atomic)
  try await waitForObservation { model.status == .externalChange }
  second.cancel()
  await second.value
  #expect(!model.isMonitoring)
  #expect(model.status == .unconfirmed)
}

@Test @MainActor func observationModelReportsStartFailureWithoutConfirmingHistoricalReceipt()
  async throws
{
  let fixture = try ObservationFixture()
  defer { fixture.cleanup() }
  let missing = fixture.directory.appendingPathComponent("missing")
  let model = SystemObservationModel(monitor: SystemFileMonitor(directory: missing))
  model.updateWorkspace(fixture.load(applied: fixture.applied))
  await model.run()
  #expect(model.observation == .unreadable(.watchUnavailable))
  #expect(!model.isMonitoring)
  #expect(model.status == .unconfirmed)
  try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
  try fixture.plan.after.write(to: missing.appendingPathComponent("hosts"))
  let restarted = Task { await model.run() }
  defer { restarted.cancel() }
  try await waitForObservation { model.status == .confirmed }
  restarted.cancel()
  await restarted.value
  #expect(model.status == .unconfirmed)
}

@Test @MainActor func systemContentsFollowReadsAndDisappearAfterFailureOrCancellation() async throws
{
  let fixture = try ObservationFixture()
  defer { fixture.cleanup() }
  let source =
    "# 🌍 foreign\r\n" + HostsSyntax.begin + "\r\n192.0.2.1 fixture.example\r\n"
    + HostsSyntax.end + "\r\n"
  let bytes = Data(source.utf8)
  try bytes.write(to: fixture.file)
  let monitor = SystemFileMonitor(directory: fixture.directory)
  let model = SystemObservationModel(monitor: monitor)
  let task = Task { await model.run() }
  defer { task.cancel() }
  try await waitForObservation { model.contents?.source == source }
  #expect(model.contents?.digest == ContentDigest(bytes))
  #expect(model.contents?.diagnostics.isEmpty == true)
  #expect(try Data(contentsOf: fixture.file) == bytes)
  try FileManager.default.removeItem(at: fixture.file)
  await model.refresh()
  try await waitForObservation { model.observation == .unreadable(.unavailable) }
  #expect(model.contents == nil)
  #expect(await monitor.contents(matching: .readable(ContentDigest(bytes))) == nil)
  let replacement = Data("# replacement\n".utf8)
  try replacement.write(to: fixture.file)
  await model.refresh()
  try await waitForObservation { model.contents?.digest == ContentDigest(replacement) }
  #expect(await monitor.contents(matching: .readable(ContentDigest(bytes))) == nil)
  task.cancel()
  await task.value
  #expect(model.contents == nil)
}

@Test func systemContentsRejectLossyEncodingAndPreserveCompleteTextPastParserLimit() {
  for bytes in [Data([0xff]), Data([0xef, 0xbb, 0xbf, 65])] {
    let contents = SystemFileContents(data: bytes)
    #expect(contents.source == nil)
    #expect(contents.digest == ContentDigest(bytes))
    #expect(contents.diagnostics.contains { $0.code == .unsupportedEncoding })
  }
  let source = String(repeating: "# line\r\n", count: HostsLimits.systemLines + 1)
  let contents = SystemFileContents(data: Data(source.utf8))
  #expect(contents.source == source)
  #expect(contents.diagnostics.contains { $0.code == .lineLimit })
  #expect(SystemFileContents(data: Data()).source == "")
}

@Test @MainActor func previewRevisionSurvivesEqualBytesAfterFailureAndRestart() async throws {
  let fixture = try ObservationFixture()
  defer { fixture.cleanup() }
  try fixture.before.write(to: fixture.file)
  let model = SystemObservationModel(monitor: SystemFileMonitor(directory: fixture.directory))
  let first = Task { await model.run() }
  defer { first.cancel() }
  try await waitForObservation { model.contents != nil }
  let contents = model.contents
  let initial = model.previewRevision
  await model.refresh()
  #expect(model.previewRevision == initial)
  try FileManager.default.removeItem(at: fixture.file)
  try await waitForObservation { model.contents == nil }
  #expect(model.previewRevision > initial)
  try fixture.before.write(to: fixture.file)
  try await waitForObservation { model.contents == contents }
  #expect(model.previewRevision > initial)
  let recovered = model.previewRevision
  first.cancel()
  await first.value
  let second = Task { await model.run() }
  defer { second.cancel() }
  try await waitForObservation { model.contents == contents }
  #expect(model.previewRevision > recovered)
  second.cancel()
  await second.value
}
