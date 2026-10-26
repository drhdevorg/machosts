import Foundation
import HostsCore
import Testing

@testable import HostsServices

private func previewInput(
  _ workspace: Workspace, system: Data = Data(), snapshot: WorkspaceSnapshot? = nil
) -> ChangePreviewInput {
  ChangePreviewInput(
    workspace: workspace,
    load: WorkspaceLoad(
      snapshot: snapshot ?? WorkspaceSnapshot(draft: workspace), readOnlyReason: nil,
      recoveryCandidate: nil),
    contents: SystemFileContents(data: system))
}

@Test func previewIncludesAllEnabledDraftsAndPreservesForeignBytes() async throws {
  var workspace = Workspace()
  workspace.profiles = [
    Profile(name: "One", source: "192.0.2.1 one.test\n", isEnabled: true),
    Profile(name: "Two", source: "2001:db8::1 two.test\n", isEnabled: true),
    Profile(name: "Inactive", source: "invalid", isEnabled: false),
  ]
  let system = Data("# Grüße 🌍\r\n127.0.0.1 localhost".utf8)
  let input = previewInput(workspace, system: system)
  let plan = try await ChangePreviewPlanner().prepare(input)
  #expect(plan.activeProfileIDs == Array(workspace.profiles.prefix(2)).map(\.id))
  #expect(plan.added.map(\.hostname) == ["one.test", "two.test"])
  #expect(plan.added[1].origins.first?.profileID == workspace.profiles[1].id)
  #expect(plan.after.starts(with: system))
  #expect(plan.before == system)
  #expect(try plan.isCurrent(workspace: workspace, system: system))
  workspace.profiles[2].name = "Renamed inactive"
  #expect(try !plan.isCurrent(workspace: workspace, system: system))
  #expect(try !plan.isCurrent(workspace: input.workspace, system: system + Data([10])))
  #expect(input != previewInput(workspace, system: system))
  let restarted = ChangePreviewInput(
    workspace: input.workspace,
    load: WorkspaceLoad(
      snapshot: input.snapshot, readOnlyReason: nil, recoveryCandidate: nil),
    contents: input.contents, observationRevision: input.observationRevision + 1)
  #expect(input != restarted)
}

@Test func previewReportsForeignConflictWithOrigins() async throws {
  var workspace = Workspace()
  workspace.profiles = [Profile(name: "Draft", source: "192.0.2.1 conflict.test", isEnabled: true)]
  do {
    _ = try await ChangePreviewPlanner().prepare(
      previewInput(workspace, system: Data("192.0.2.2 conflict.test".utf8)))
    Issue.record("Expected conflict")
  } catch ChangePreviewFailure.plan(.conflicts(let conflicts)) {
    #expect(conflicts.count == 1)
    #expect(
      conflicts[0].mappings.flatMap(\.origins).map(\.profileID) == [nil, workspace.profiles[0].id])
  }
}

@Test func previewRejectsUnownedBlockAndExposesParserLocations() async throws {
  var workspace = Workspace()
  let system = Data("\(HostsSyntax.begin)\n192.0.2.1 old.test\n\(HostsSyntax.end)\n".utf8)
  await #expect(throws: ChangePreviewFailure.plan(.managedBlockChanged)) {
    try await ChangePreviewPlanner().prepare(previewInput(workspace, system: system))
  }
  workspace.profiles = [Profile(name: "Broken", source: "# comment\r\ninvalid", isEnabled: true)]
  do {
    _ = try await ChangePreviewPlanner().prepare(previewInput(workspace))
    Issue.record("Expected diagnostics")
  } catch ChangePreviewFailure.plan(.invalidDocuments(let diagnostics)) {
    #expect(diagnostics.first?.profileID == workspace.profiles[0].id)
    #expect(diagnostics.first?.diagnostic.line == 2)
  }
}

@Test func previewRequiresSavedReadableWritableInput() async throws {
  let workspace = Workspace()
  var changed = workspace
  changed.profiles = [Profile(name: "Unsaved")]
  let load = WorkspaceLoad(
    snapshot: WorkspaceSnapshot(draft: workspace), readOnlyReason: nil, recoveryCandidate: nil)
  let planner = ChangePreviewPlanner()
  await #expect(throws: ChangePreviewFailure.unsavedDraft) {
    try await planner.prepare(
      ChangePreviewInput(workspace: changed, load: load, contents: SystemFileContents(data: Data()))
    )
  }
  for contents in [nil, SystemFileContents(data: Data([0xff]))] {
    await #expect(throws: ChangePreviewFailure.unavailable) {
      try await planner.prepare(
        ChangePreviewInput(workspace: workspace, load: load, contents: contents))
    }
  }
  let readOnly = WorkspaceLoad(
    snapshot: load.snapshot, readOnlyReason: .externalChange, recoveryCandidate: nil)
  await #expect(throws: ChangePreviewFailure.unavailable) {
    try await planner.prepare(
      ChangePreviewInput(
        workspace: workspace, load: readOnly, contents: SystemFileContents(data: Data())))
  }
}

@Test func previewBlocksPendingIntentAndDoesNotCreateAppliedEvidence() async throws {
  var workspace = Workspace()
  workspace.profiles = [Profile(name: "One", source: "192.0.2.1 one.test", isEnabled: true)]
  let plan = try await ChangePreviewPlanner().prepare(previewInput(workspace))
  let pending = try PendingApply(workspace: workspace, plan: plan)
  let snapshot = WorkspaceSnapshot(draft: workspace, pendingApply: pending)
  await #expect(throws: ChangePreviewFailure.recoveryRequired) {
    try await ChangePreviewPlanner().prepare(previewInput(workspace, snapshot: snapshot))
  }
  #expect(snapshot.applied == nil)
  #expect(snapshot.pendingApply == pending)
}

@Test func previewRemovesOnlyOwnedBlockAndRetainsSeparatorEvidence() async throws {
  var workspace = Workspace()
  workspace.profiles = [Profile(name: "One", source: "192.0.2.1 one.test", isEnabled: true)]
  let original = Data("# foreign without terminator".utf8)
  let first = try await ChangePreviewPlanner().prepare(previewInput(workspace, system: original))
  let pending = try PendingApply(workspace: workspace, plan: first)
  let receipt = ApplyReceipt(
    transactionID: first.id, beforeDigest: first.expectedSystemDigest,
    afterDigest: first.resultingSystemDigest, backupID: UUID(), readback: .verified,
    cacheFlush: .notAttempted)
  let applied = try AppliedWorkspaceSnapshot(pending: pending, receipt: receipt)
  workspace.profiles[0].isEnabled = false
  let snapshot = WorkspaceSnapshot(draft: workspace, applied: applied)
  let removal = try await ChangePreviewPlanner().prepare(
    previewInput(workspace, system: first.after, snapshot: snapshot))
  #expect(removal.operation == .removeManagedBlock)
  #expect(removal.after == original)
  #expect(removal.removed.map(\.hostname) == ["one.test"])
  let locations = try await ChangePreviewPlanner().locations(
    in: previewInput(workspace, system: first.after, snapshot: snapshot),
    plan: removal, failure: nil)
  #expect(locations.isEmpty)
}

@Test func previewNavigationBindsUnicodeLinesAndRejectsChangedOrDeletedSources() throws {
  var workspace = Workspace()
  let source = "# Grüße 🌍\r\n192.0.2.1 one.test\rinvalid\n"
  let profile = Profile(name: "Draft", source: source, isEnabled: true)
  workspace.profiles = [profile]
  let input = previewInput(workspace)
  let target = try #require(
    ChangePreviewLocation(input: input, profileID: profile.id, line: 2))
  let range = try #require(target.range(in: workspace))
  #expect((source as NSString).substring(with: range) == "192.0.2.1 one.test")
  let invalid = try #require(
    ChangePreviewLocation(input: input, profileID: profile.id, line: 3))
  #expect(
    (source as NSString).substring(with: try #require(invalid.range(in: workspace))) == "invalid")
  workspace.profiles[0].name = "Renamed"
  #expect(target.range(in: workspace) == range)
  workspace.profiles[0].source = "# shifted\n" + source
  #expect(target.range(in: workspace) == nil)
  workspace.profiles.removeAll()
  #expect(target.range(in: workspace) == nil)
  #expect(ChangePreviewLocation(input: input, profileID: nil, line: 2) == nil)
  #expect(ChangePreviewLocation(input: input, profileID: UUID(), line: 2) == nil)
  #expect(ChangePreviewLocation(input: input, profileID: profile.id, line: nil) == nil)
  #expect(ChangePreviewLocation(input: input, profileID: profile.id, line: 99) == nil)
}

@Test func previewIndexesDisplayedCurrentOriginsAndParserErrors() async throws {
  var workspace = Workspace()
  let profile = Profile(
    name: "Current", source: "# 🌍\r\n192.0.2.1 conflict.test\n", isEnabled: true)
  workspace.profiles = [profile]
  let planner = ChangePreviewPlanner()
  let input = previewInput(workspace)
  let plan = try await planner.prepare(input)
  let added = try await planner.locations(in: input, plan: plan, failure: nil)
  let target = try #require(added[profile.id]?[2])
  #expect(
    (profile.source as NSString).substring(with: try #require(target.range(in: workspace)))
      == "192.0.2.1 conflict.test")
  #expect(added[profile.id]?.count == 1)
  do {
    _ = try await planner.prepare(
      previewInput(workspace, system: Data("192.0.2.2 conflict.test".utf8)))
    Issue.record("Expected conflict")
  } catch let failure as ChangePreviewFailure {
    let conflicts = try await planner.locations(in: input, plan: nil, failure: failure)
    #expect(conflicts == added)
  }
  workspace.profiles[0].source = "# 🌍\r\ninvalid"
  let broken = previewInput(workspace)
  do {
    _ = try await planner.prepare(broken)
    Issue.record("Expected diagnostic")
  } catch let failure as ChangePreviewFailure {
    let diagnostics = try await planner.locations(in: broken, plan: nil, failure: failure)
    let target = try #require(diagnostics[profile.id]?[2])
    #expect(
      (workspace.profiles[0].source as NSString).substring(
        with: try #require(target.range(in: workspace))) == "invalid")
  }
  let empty = try await planner.locations(in: input, plan: nil, failure: .unavailable)
  #expect(empty.isEmpty)
}
