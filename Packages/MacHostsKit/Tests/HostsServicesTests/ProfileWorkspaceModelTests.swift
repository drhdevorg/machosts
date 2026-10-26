import Foundation
import HostsCore
import Synchronization
import Testing

@testable import HostsServices

private struct EditorFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "machosts-editor-" + UUID().uuidString)
  func cleanup() {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Editor fixture cleanup failed")
    }
  }
}

@Test @MainActor func profileEditingPersistsDesiredStateWithoutAppliedReceipt() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
    let id = try #require(model.create(name: "Staging"))
    model.setSource(id, source: "192.0.2.4 shop.example\r\n# café\r\n")
    model.setEnabled(id, enabled: true)
    model.rename(id, name: "Shop")
    #expect(model.hasUnsavedChanges && model.hasUnappliedChanges)
    #expect(await model.flush())
    #expect(!model.hasUnsavedChanges)
    #expect(model.hasUnappliedChanges)
    #expect(model.persisted.snapshot?.applied == nil)
    #expect(model.persisted.snapshot?.pendingApply == nil)
  }
  let reopened = try await WorkspaceStore.open(directory: fixture.directory)
  let draft = try #require(await reopened.state().snapshot?.draft)
  #expect(draft.profiles.count == 1)
  #expect(draft.profiles[0].source == "192.0.2.4 shop.example\r\n# café\r\n")
  #expect(draft.profiles[0].name == "Shop")
  #expect(draft.profiles[0].isEnabled)
}

@Test @MainActor func profileEditingDuplicateTrashRestoreAndOrdering() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let first = try #require(model.create(name: "First"))
  model.setSource(first, source: "192.0.2.1 first.example\n")
  model.setEnabled(first, enabled: true)
  let second = try #require(model.duplicate(first, name: "Copy"))
  #expect(model.workspace.profiles[1].source == model.workspace.profiles[0].source)
  #expect(!model.workspace.profiles[1].isEnabled)
  model.move(second, by: -1)
  #expect(model.workspace.profiles.map(\.id) == [second, first])
  model.delete(first)
  #expect(model.workspace.trash.first?.profile.isEnabled == true)
  model.restore(first)
  #expect(model.workspace.profiles.map(\.id) == [second, first])
  #expect(!model.workspace.profiles[1].isEnabled)
  #expect(model.workspace.trash.isEmpty)
  #expect(await model.flush())
  #expect(await store.state().snapshot?.draft == model.workspace)
}

@Test @MainActor func profileEditorRejectsStaleLineActionsAndInvalidChanges() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let id = try #require(model.create(name: "Test"))
  model.setSource(id, source: "192.0.2.1 one.example\r\n")
  let digest = ContentDigest(Data(model.workspace.profiles[0].source.utf8))
  model.toggleLine(id, number: 1, expectedDigest: digest)
  #expect(model.workspace.profiles[0].source == HostsSyntax.disabled + "192.0.2.1 one.example\r\n")
  let preserved = model.workspace
  model.toggleLine(id, number: 1, expectedDigest: digest)
  #expect(model.editFailure == .staleRevision)
  #expect(model.workspace == preserved)
  model.rename(id, name: "\n")
  #expect(model.editFailure == .invalidName)
  model.setSource(id, source: String(repeating: "a", count: HostsLimits.profileBytes + 1))
  #expect(model.editFailure == .limitExceeded)
  #expect(model.workspace == preserved)
  // Invalid hosts syntax is a legitimate local draft and remains available for correction.
  model.setSource(id, source: "invalid input")
  #expect(model.editFailure == nil)
  #expect(await model.flush())
  #expect(await store.state().snapshot?.draft.profiles[0].source == "invalid input")
}

@Test @MainActor func remoteProfileOnlyBecomesEditableThroughInactiveLocalCopy() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  _ = try await store.saveDraft(
    Workspace(
      revision: 1,
      profiles: [
        Profile(name: "Remote", kind: .remote, source: "192.0.2.1 remote.example", isEnabled: true)
      ]), expectedGeneration: 0)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let remote = model.workspace.profiles[0]
  model.setSource(remote.id, source: "replacement")
  #expect(model.editFailure == .readOnlyProfile)
  #expect(model.workspace.profiles[0] == remote)
  let local = try #require(model.duplicate(remote.id, name: "Local"))
  model.setSource(local, source: "192.0.2.2 local.example")
  #expect(model.workspace.profiles[1].kind == .local)
  #expect(!model.workspace.profiles[1].isEnabled)
  #expect(await model.flush())
}

@Test @MainActor func editorSaveFailureRetainsDraftAndAllowsExplicitRetry() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let fault = EditorSaveFault()
  let store = try await WorkspaceStore.open(directory: fixture.directory) { point in
    if point == .beforeRename, fault.shouldFail { throw WorkspaceStoreFailure.io(28) }
  }
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let id = try #require(model.create(name: "Unsaved"))
  #expect(!(await model.flush()))
  #expect(model.saveFailed && model.hasUnsavedChanges)
  #expect(model.workspace.profiles[0].id == id)
  #expect(await store.state().snapshot?.draft.profiles.isEmpty == true)
  fault.disable()
  #expect(await model.flush())
  #expect(!model.saveFailed && !model.hasUnsavedChanges)
  #expect(await store.state().snapshot?.draft == model.workspace)
}

private final class EditorSaveFault: Sendable {
  private let enabled = Mutex(true)
  var shouldFail: Bool { enabled.withLock { $0 } }
  func disable() { enabled.withLock { $0 = false } }
}

@Test @MainActor func editorReadOnlyWorkspaceNeverStartsEmptyWritableSession() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  try FileManager.default.createDirectory(
    at: fixture.directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let file = fixture.directory.appendingPathComponent("workspace.json")
  let original = Data("{\"schemaVersion\":99}".utf8)
  try original.write(to: file)
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store)
  #expect(model.isReadOnly)
  #expect(model.create(name: "Forbidden") == nil)
  #expect(!model.hasUnsavedChanges)
  #expect(try Data(contentsOf: file) == original)
}

@Test @MainActor func editorDrainsNewerEditsAndJoinsConcurrentFlushes() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let id = try #require(model.create(name: "Changing"))
  let first = Task { await model.flush() }
  await Task.yield()
  model.setSource(id, source: "192.0.2.3 newest.example")
  let second = Task { await model.flush() }
  #expect(await first.value)
  #expect(await second.value)
  #expect(await model.flush())
  #expect(!model.hasUnsavedChanges)
  #expect(await store.state().snapshot?.draft == model.workspace)
}

@Test @MainActor func editorPreservesReceiptAndInterruptedIntentDuringLocalEdits() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let workspace = Workspace(
    revision: 1,
    profiles: [Profile(name: "Applied", source: "192.0.2.1 test.example\n", isEnabled: true)])
  let plan = try ApplyPlan.prepare(workspace: workspace, system: Data("# foreign\n".utf8))
  let applied = try AppliedWorkspaceSnapshot(
    workspace: workspace, plan: plan,
    receipt: ApplyReceipt(
      transactionID: plan.id, beforeDigest: plan.expectedSystemDigest,
      afterDigest: plan.resultingSystemDigest, backupID: UUID(), readback: .verified,
      cacheFlush: .notAttempted))
  let first = try await store.saveDraft(workspace, expectedGeneration: 0)
  let recorded = try await store.recordApplied(applied, expectedGeneration: first.generation)
  let pending = try PendingApply(workspace: workspace, plan: plan)
  try await store.beginApply(pending, expectedGeneration: recorded.generation)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  #expect(!model.hasUnappliedChanges)
  model.setSource(workspace.profiles[0].id, source: "192.0.2.2 test.example\n")
  #expect(model.hasUnappliedChanges)
  #expect(await model.flush())
  #expect(model.persisted.snapshot?.applied == applied)
  #expect(model.persisted.snapshot?.pendingApply == pending)
  #expect(model.workspace.profiles[0].source == "192.0.2.2 test.example\n")
}

@Test @MainActor func editorDetectsExternalWorkspaceMutationAndRetainsVisibleDraft() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let id = try #require(model.create(name: "Original"))
  #expect(await model.flush())
  let file = fixture.directory.appendingPathComponent("workspace.json")
  let external = Data("externally replaced workspace".utf8)
  try external.write(to: file)
  model.setSource(id, source: "192.0.2.1 retained.example")
  let retained = model.workspace
  #expect(!(await model.flush()))
  #expect(model.isReadOnly && model.saveFailed && model.hasUnsavedChanges)
  #expect(model.workspace == retained)
  #expect(model.create(name: "Rejected") == nil)
  #expect(try Data(contentsOf: file) == external)
}

@Test @MainActor func editorAutosavesLatestDraftAfterTypingStops() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .milliseconds(10))
  let id = try #require(model.create(name: "Autosave"))
  for index in 1...10 { model.setSource(id, source: "192.0.2.\(index) auto.example\n") }
  let deadline = ContinuousClock.now + .seconds(3)
  while model.hasUnsavedChanges, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(!model.hasUnsavedChanges && !model.saveFailed)
  #expect(await store.state().snapshot?.draft.profiles[0].source == "192.0.2.10 auto.example\n")
  #expect(await store.state().snapshot?.applied == nil)
}

@Test @MainActor func editorFoldersPreserveProfilesOrderActivationAndTrashAcrossRestart()
  async throws
{
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  var expected: Workspace?
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
    let root = try #require(model.createFolder(name: "Team"))
    let child = try #require(model.createFolder(name: "Staging", parentID: root))
    let grandchild = try #require(model.createFolder(name: "Shop", parentID: child))
    let sibling = try #require(model.createFolder(name: "Other", parentID: root))
    model.moveFolder(sibling, by: -1)
    #expect(model.workspace.folders.filter { $0.parentID == root }.map(\.id) == [sibling, child])
    model.renameFolder(root, name: "Projects")
    let live = try #require(model.create(name: "Active"))
    model.setSource(live, source: "192.0.2.1 shop.example\r\n# café\r\n")
    model.setEnabled(live, enabled: true)
    model.moveToFolder(live, folderID: child)
    let copy = try #require(model.duplicate(live, name: "Deleted"))
    model.delete(copy)
    model.removeFolder(child)
    #expect(model.workspace.folders.first { $0.id == grandchild }?.parentID == root)
    #expect(model.workspace.profiles[0].folderID == root)
    #expect(model.workspace.profiles[0].isEnabled)
    #expect(model.workspace.profiles[0].source == "192.0.2.1 shop.example\r\n# café\r\n")
    model.restore(copy)
    #expect(model.workspace.profiles.map(\.id) == [live, copy])
    #expect(model.workspace.profiles[1].folderID == nil)
    #expect(!model.workspace.profiles[1].isEnabled)
    #expect(await model.flush())
    #expect(model.persisted.snapshot?.applied == nil)
    expected = model.workspace
  }
  let reopened = try await WorkspaceStore.open(directory: fixture.directory)
  #expect(await reopened.state().snapshot?.draft == expected)
}

@Test @MainActor func editorRejectsInvalidFolderGraphsWithoutPartialMutation() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let root = try #require(model.createFolder(name: "Root"))
  var parent = root
  for level in 2...HostsLimits.folderDepth {
    parent = try #require(model.createFolder(name: "Level \(level)", parentID: parent))
  }
  let id = try #require(model.create(name: "Test"))
  let valid = model.workspace
  #expect(model.createFolder(name: "Too deep", parentID: parent) == nil)
  #expect(model.editFailure == .invalidFolder)
  model.reparentFolder(root, parentID: parent)
  #expect(model.editFailure == .invalidFolder)
  model.reparentFolder(root, parentID: root)
  #expect(model.editFailure == .invalidFolder)
  model.moveToFolder(id, folderID: UUID())
  #expect(model.editFailure == .invalidFolder)
  model.renameFolder(root, name: "\n")
  #expect(model.editFailure == .invalidName)
  model.removeFolder(UUID())
  #expect(model.editFailure == .invalidFolder)
  #expect(model.workspace == valid)
  #expect(await model.flush())
}

@Test func profileSearchUsesLiteralUTF16RangesAcrossDraftKindsAndLineEndings() async throws {
  let local = Profile(
    name: "Local", source: "# 😀 café\r\n\r\n192.0.2.1 SHOP.example\r# [a.*] literal\n")
  let remote = Profile(
    name: "Shop remote", kind: .remote, source: "# shop.example\n", isEnabled: true)
  let trashed = Profile(name: "Shop trash", source: "shop.example")
  let workspace = Workspace(
    profiles: [local, remote],
    trash: [.init(profile: trashed, formerIndex: 0)])
  let search = ProfileSearch()
  let result = await search.search("shop", in: workspace)
  #expect(result.hits.map(\.profileID) == [local.id, remote.id, remote.id])
  #expect(result.hits.map(\.line) == [3, nil, 1])
  for hit in result.hits {
    let profile = try #require(workspace.profiles.first { $0.id == hit.profileID })
    #expect(hit.digest == ContentDigest(Data(profile.source.utf8)))
    if let range = hit.range {
      #expect((profile.source as NSString).substring(with: range).lowercased() == "shop")
    }
  }
  let literal = await search.search("[a.*]", in: workspace)
  #expect(literal.hits.count == 1)
  let hit = try #require(literal.hits.first)
  #expect(hit.line == 4)
  #expect((local.source as NSString).substring(with: try #require(hit.range)) == "[a.*]")
  #expect(await search.search("", in: workspace).hits.isEmpty)
  #expect(await search.search("missing", in: workspace).hits.isEmpty)
  #expect(workspace.profiles == [local, remote])
}

@Test func profileSearchReportsTruncationAndUsesTheNewSnapshot() async {
  let profile = Profile(name: "Name", source: String(repeating: "# needle\n", count: 201))
  let search = ProfileSearch()
  let initial = Workspace(profiles: [profile])
  let result = await search.search("needle", in: initial)
  #expect(result.hits.count == 200)
  #expect(result.isTruncated)
  var changed = initial
  changed.profiles[0].source = "replacement"
  let refreshed = await search.search("needle", in: changed)
  #expect(refreshed.hits.isEmpty && !refreshed.isTruncated)
  let deleted = await search.search("needle", in: Workspace())
  #expect(deleted.hits.isEmpty)
}

@Test @MainActor func editorMovesProfilesAmongVisibleFolderSiblings() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let folder = try #require(model.createFolder(name: "Group"))
  let first = try #require(model.create(name: "First"))
  let other = try #require(model.create(name: "Other folder"))
  let last = try #require(model.create(name: "Last"))
  model.moveToFolder(first, folderID: folder)
  model.moveToFolder(last, folderID: folder)
  model.move(last, by: -1)
  #expect(model.workspace.profiles.map(\.id) == [last, first, other])
  model.move(last, by: -1)
  #expect(model.workspace.profiles.map(\.id) == [last, first, other])
  model.move(last, by: 1)
  #expect(model.workspace.profiles.map(\.id) == [first, last, other])
  #expect(model.workspace.profiles.filter { $0.folderID == folder }.map(\.id) == [first, last])
  #expect(await model.flush())
}

@Test @MainActor func editorRecoveryRequiresExplicitActionAndResumesEditing() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let saved = Workspace(revision: 1, profiles: [Profile(name: "Saved", source: "# café\r\n")])
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    _ = try await store.saveDraft(saved, expectedGeneration: 0)
    var newer = saved
    newer.revision = 2
    newer.profiles[0].source = "# newer"
    _ = try await store.saveDraft(newer, expectedGeneration: 1)
  }
  let file = fixture.directory.appendingPathComponent("workspace.json")
  let broken = Data("{truncated".utf8)
  try broken.write(to: file)
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store)
  #expect(model.canRecoverPrevious && model.isReadOnly)
  #expect(model.persisted.recoveryCandidate?.draft == saved)
  #expect(model.create(name: "Blocked") == nil)
  #expect(try Data(contentsOf: file) == broken)
  #expect(await model.recoverPrevious())
  #expect(!model.isReadOnly && !model.canRecoverPrevious && !model.recoveryFailed)
  #expect(model.workspace == saved)
  #expect(model.persisted.snapshot?.applied == nil)
  let archives = try FileManager.default.contentsOfDirectory(
    at: fixture.directory, includingPropertiesForKeys: nil
  ).filter { $0.lastPathComponent.hasPrefix("workspace.recovery-") }
  #expect(archives.count == 1)
  #expect(try Data(contentsOf: #require(archives.first)) == broken)
  model.setSource(saved.profiles[0].id, source: "# recovered and edited")
  #expect(await model.flush())
  #expect(await store.state().snapshot?.draft == model.workspace)
  #expect(!(await model.recoverPrevious()))
}

@Test @MainActor func editorRecoveryRejectsChangedBytesAndUnsupportedSchemas() async throws {
  for unsupported in [false, true] {
    let fixture = EditorFixture()
    defer { fixture.cleanup() }
    do {
      let store = try await WorkspaceStore.open(directory: fixture.directory)
      _ = try await store.saveDraft(
        Workspace(revision: 1, profiles: [Profile(name: "Previous")]), expectedGeneration: 0)
      _ = try await store.saveDraft(Workspace(revision: 2), expectedGeneration: 1)
    }
    let file = fixture.directory.appendingPathComponent("workspace.json")
    let original = Data((unsupported ? "{\"schemaVersion\":99}" : "broken").utf8)
    try original.write(to: file)
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    let model = try await ProfileWorkspaceModel.open(store: store)
    #expect(model.canRecoverPrevious == !unsupported)
    let preserved = unsupported ? original : Data("external change after review".utf8)
    if !unsupported { try preserved.write(to: file) }
    #expect(!(await model.recoverPrevious()))
    #expect(model.isReadOnly && !model.isRecovering)
    #expect(model.workspace.profiles.isEmpty)
    #expect(try Data(contentsOf: file) == preserved)
    #expect(model.recoveryFailed == !unsupported)
  }
}

@Test @MainActor func editorRecoveryWriteFailureKeepsCandidateAndReadOnlyState() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    _ = try await store.saveDraft(
      Workspace(revision: 1, profiles: [Profile(name: "Preserved")]), expectedGeneration: 0)
    _ = try await store.saveDraft(Workspace(revision: 2), expectedGeneration: 1)
  }
  let file = fixture.directory.appendingPathComponent("workspace.json")
  let broken = Data("broken".utf8)
  try broken.write(to: file)
  let store = try await WorkspaceStore.open(directory: fixture.directory) { point in
    if point == .beforeRename { throw WorkspaceStoreFailure.io(28) }
  }
  let model = try await ProfileWorkspaceModel.open(store: store)
  #expect(!(await model.recoverPrevious()))
  #expect(model.recoveryFailed && model.isReadOnly && !model.isRecovering)
  #expect(model.persisted.recoveryCandidate?.draft.profiles.first?.name == "Preserved")
  #expect(model.create(name: "Rejected") == nil)
  #expect(try Data(contentsOf: file) == broken)
}

@Test @MainActor func trashReviewAndRestorePreserveSavedSourceAndRemoteIdentity() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let source = "# café 🐈\r\n192.0.2.8 trash.example\r\ninvalid draft\r\n"
  let folder = ProfileFolder(name: "Former folder")
  let profile = Profile(
    name: "Remote archive", folderID: folder.id, kind: .remote, source: source, isEnabled: true)
  do {
    let store = try await WorkspaceStore.open(directory: fixture.directory)
    _ = try await store.saveDraft(
      Workspace(revision: 1, profiles: [profile], folders: [folder]), expectedGeneration: 0)
    let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
    model.delete(profile.id)
    model.removeFolder(folder.id)
    #expect(await model.flush())
  }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let before = model.workspace
  let item = try #require(model.workspace.trash.first)
  #expect(item.profile == profile)
  #expect(!model.hasUnsavedChanges)
  #expect(model.workspace == before)
  model.restore(profile.id)
  let restored = try #require(model.workspace.profiles.first)
  #expect(restored.id == profile.id)
  #expect(restored.source == source)
  #expect(restored.kind == .remote)
  #expect(restored.folderID == nil)
  #expect(!restored.isEnabled)
  #expect(model.workspace.trash.isEmpty)
  #expect(await model.flush())
  #expect(await store.state().snapshot?.draft == model.workspace)
  #expect(model.persisted.snapshot?.applied == nil)
  #expect(model.persisted.snapshot?.pendingApply == nil)
}

@Test @MainActor func restoringTrashAtCombinedProfileLimitPreservesBothCollections() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let archived = Profile(name: "Archived", source: "# preserved\r\n", isEnabled: true)
  let profiles = (0..<499).map { Profile(name: "Profile \($0)") }
  _ = try await store.saveDraft(
    Workspace(revision: 1, profiles: profiles, trash: [.init(profile: archived, formerIndex: 0)]),
    expectedGeneration: 0)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let before = model.workspace
  #expect(model.create(name: "Over limit") == nil)
  #expect(model.editFailure == .limitExceeded)
  #expect(model.workspace == before)
  #expect(!model.hasUnsavedChanges)
  model.restore(archived.id)
  #expect(model.editFailure == nil)
  #expect(model.workspace.profiles.first?.id == archived.id)
  #expect(model.workspace.profiles.first?.isEnabled == false)
  #expect(model.workspace.trash.isEmpty)
  #expect(model.workspace.profiles.count == 500)
  #expect(await model.flush())
}

@Test @MainActor func profileOrderingAvailabilityTracksSiblingsAndPersistsActions() async throws {
  let fixture = EditorFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let folder = try #require(model.createFolder(name: "Group"))
  let first = try #require(model.create(name: "First"))
  let unrelated = try #require(model.create(name: "Unfiled"))
  let last = try #require(model.create(name: "Last"))
  model.moveToFolder(first, folderID: folder)
  model.moveToFolder(last, folderID: folder)
  model.setSource(first, source: "# café\r\n192.0.2.5 alias.example\r\n")
  model.setEnabled(first, enabled: true)
  #expect(!model.canMove(first, by: -1))
  #expect(model.canMove(first, by: 1))
  #expect(!model.canMove(unrelated, by: 1))
  #expect(!model.canMove(UUID(), by: -1))
  #expect(!model.canMove(last, by: Int.max))
  #expect(!model.canMove(first, by: 0))
  let original = model.workspace
  model.move(first, by: -1)
  #expect(model.workspace == original)
  let copy = try #require(model.duplicate(first, name: "First"))
  #expect(model.workspace.profiles.first { $0.id == copy }?.folderID == folder)
  #expect(model.workspace.profiles.first { $0.id == copy }?.isEnabled == false)
  model.move(copy, by: 1)
  #expect(!model.canMove(copy, by: 1))
  model.delete(last)
  #expect(model.canMove(copy, by: -1))
  model.moveToFolder(copy, folderID: nil)
  #expect(model.canMove(copy, by: -1))
  #expect(!model.canMove(first, by: 1))
  #expect(await model.flush())
  let saved = try #require(await store.state().snapshot)
  #expect(saved.draft == model.workspace)
  #expect(saved.applied == nil && saved.pendingApply == nil)
  #expect(saved.draft.profiles.first { $0.id == copy }?.source == original.profiles[0].source)
}
