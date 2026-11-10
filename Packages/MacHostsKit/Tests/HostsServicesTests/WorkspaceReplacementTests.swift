import Darwin
import Foundation
import HostsCore
import Testing

@testable import HostsServices

private func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "machosts-replace-" + UUID().uuidString)
}

private func remove(_ directory: URL) {
  chmod(directory.path, 0o700)
  do { try FileManager.default.removeItem(at: directory) } catch {
    Issue.record("Cleanup failed")
  }
}

private func incomingDocument() throws -> WorkspaceExchangeDocument {
  let folder = ProfileFolder(name: "Imported")
  return try WorkspaceExchangeDocument(
    workspace: Workspace(
      profiles: [
        Profile(name: "New", folderID: folder.id, source: "192.0.2.9 new.test\n", isEnabled: true)
      ], folders: [folder]))
}

@Test func replacementDraftContainsOnlyTheImportAndContinuesTheRevision() throws {
  let current = Workspace(
    revision: 7, profiles: [Profile(name: "Old", source: "192.0.2.1 old.test")],
    trash: [.init(profile: Profile(name: "Deleted"), formerIndex: 0)])
  let replaced = try incomingDocument().replacing(current)
  #expect(replaced.revision == 7)
  #expect(replaced.profiles.map(\.name) == ["New"])
  #expect(replaced.trash.isEmpty && replaced.folders.count == 1)
  #expect(replaced.profiles[0].isEnabled == false && replaced.profiles[0].kind == .local)
  #expect(replaced.profiles[0].folderID == replaced.folders[0].id)
}

@Test @MainActor func replacementSavesAndBacksUpTheExactCurrentDraftFirst() async throws {
  let directory = temporaryDirectory()
  defer { remove(directory) }
  let backup: String
  let before: Workspace
  do {
    let store = try await WorkspaceStore.open(directory: directory)
    let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
    let kept = try #require(model.create(name: "Old"))
    model.setEnabled(kept, enabled: true)
    let deleted = try #require(model.create(name: "Deleted"))
    model.delete(deleted)
    // Unsaved edits must reach the backup: replacement flushes before backing up.
    #expect(model.hasUnsavedChanges)
    before = model.workspace
    let applied = model.persisted.snapshot?.applied

    backup = try #require(await model.replaceWorkspace(with: try incomingDocument()))
    #expect(backup.hasPrefix("workspace.backup-") && backup.hasSuffix(".json"))
    #expect(await model.backups() == [backup])
    #expect(try await store.readBackup(backup).draft == before)
    #expect(model.workspace.revision == before.revision + 1)
    #expect(model.workspace.profiles.map(\.name) == ["New"])
    #expect(model.workspace.trash.isEmpty)
    #expect(model.workspace.profiles.allSatisfy { !$0.isEnabled })
    #expect(!model.hasUnsavedChanges && !model.isReadOnly)
    #expect(model.persisted.snapshot?.applied == applied)
    #expect(model.persisted.snapshot?.pendingApply == nil)
  }
  let reopened = try await WorkspaceStore.open(directory: directory)
  #expect(await reopened.state().snapshot?.draft.profiles.map(\.name) == ["New"])
  #expect(try await reopened.readBackup(backup).draft == before)
}

@Test @MainActor func restoringABackupBacksUpTheReplacedDraftAndRestoresTrash() async throws {
  let directory = temporaryDirectory()
  defer { remove(directory) }
  let store = try await WorkspaceStore.open(directory: directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  _ = try #require(model.create(name: "Old"))
  model.delete(try #require(model.create(name: "Deleted")))
  let original = model.workspace
  let first = try #require(await model.replaceWorkspace(with: try incomingDocument()))
  let replaced = model.workspace

  let second = try #require(await model.restoreBackup(first))
  #expect(second != first)
  #expect(Set(await model.backups()) == [first, second])
  #expect(try await store.readBackup(second).draft == replaced)
  #expect(model.workspace.profiles == original.profiles)
  #expect(model.workspace.trash == original.trash)
  #expect(model.workspace.revision == replaced.revision + 1)
  #expect(!model.hasUnsavedChanges)
}

@Test @MainActor func failedBackupLeavesTheDraftUnchangedAndEditable() async throws {
  let directory = temporaryDirectory()
  defer { remove(directory) }
  let store = try await WorkspaceStore.open(directory: directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  _ = try #require(model.create(name: "Old"))
  #expect(await model.flush())
  let before = model.workspace
  // A private directory that refuses new files makes the backup step fail.
  #expect(chmod(directory.path, 0o500) == 0)
  #expect(await model.replaceWorkspace(with: try incomingDocument()) == nil)
  #expect(chmod(directory.path, 0o700) == 0)
  #expect(model.editFailure == .backupFailed)
  #expect(model.workspace == before)
  #expect(!model.isReadOnly && !model.hasUnsavedChanges)
  #expect(await model.backups().isEmpty)
  #expect(await store.state().snapshot?.draft == before)
}

@Test func backupsAreReadOnlyByListedName() async throws {
  let directory = temporaryDirectory()
  defer { remove(directory) }
  let store = try await WorkspaceStore.open(directory: directory)
  _ = try await store.saveDraft(
    Workspace(revision: 1, profiles: [Profile(name: "A")]), expectedGeneration: 0)
  let generation = try #require(await store.state().snapshot?.generation)
  let name = try await store.writeBackup(expectedGeneration: generation)
  #expect(try await store.readBackup(name).draft.profiles.map(\.name) == ["A"])
  for unlisted in ["workspace.json", "workspace.previous.json", "../" + name, "missing.json"] {
    await #expect(throws: WorkspaceStoreFailure.unsafeFile) {
      _ = try await store.readBackup(unlisted)
    }
  }
  await #expect(throws: WorkspaceStoreFailure.staleGeneration) {
    _ = try await store.writeBackup(expectedGeneration: generation + 1)
  }
}
