import Foundation
import HostsCore
import Observation

/// Shared local draft editing. This model never reads or writes the system hosts file.
@MainActor @Observable
public final class ProfileWorkspaceModel {
  public private(set) var workspace: Workspace
  public private(set) var persisted: WorkspaceLoad
  public private(set) var isSaving = false
  public private(set) var saveFailed = false
  public private(set) var editFailure: WorkspaceFailure?
  private let store: WorkspaceStore
  private let autosave: WorkspaceAutosave?
  private let delay: Duration
  private var savedDraft: Workspace
  @ObservationIgnored private var debounce: Task<Void, Never>?
  @ObservationIgnored private var saving: Task<Bool, Never>?

  private init(
    store: WorkspaceStore, load: WorkspaceLoad, autosave: WorkspaceAutosave?, delay: Duration
  ) {
    self.store = store
    persisted = load
    workspace = load.snapshot?.draft ?? Workspace()
    savedDraft = load.snapshot?.draft ?? Workspace()
    self.autosave = autosave
    self.delay = delay
  }

  public static func open(store: WorkspaceStore) async throws -> ProfileWorkspaceModel {
    try await open(store: store, delay: .milliseconds(350))
  }

  static func open(store: WorkspaceStore, delay: Duration) async throws -> ProfileWorkspaceModel {
    let load = await store.state()
    let autosave =
      load.snapshot != nil && load.readOnlyReason == nil
      ? try await WorkspaceAutosave.open(store: store, delay: .milliseconds(350)) : nil
    return ProfileWorkspaceModel(store: store, load: load, autosave: autosave, delay: delay)
  }

  public var isReadOnly: Bool { autosave == nil || persisted.readOnlyReason != nil }
  public var hasUnsavedChanges: Bool { workspace != savedDraft }
  public var hasUnappliedChanges: Bool {
    guard let applied = persisted.snapshot?.applied else { return !workspace.profiles.isEmpty }
    return workspace != applied.workspace
  }

  @discardableResult
  public func create(name: String) -> UUID? {
    let profile = Profile(name: name)
    return change { $0.profiles.append(profile) } ? profile.id : nil
  }

  public func rename(_ id: UUID, name: String) {
    update(id) { $0.name = name }
  }

  public func setSource(_ id: UUID, source: String) {
    update(id) {
      guard $0.kind == .local else { throw WorkspaceFailure.readOnlyProfile }
      $0.source = source
    }
  }

  public func setEnabled(_ id: UUID, enabled: Bool) {
    update(id) { $0.isEnabled = enabled }
  }

  public func toggleLine(_ id: UUID, number: Int, expectedDigest: ContentDigest) {
    change { draft in
      guard let index = draft.profiles.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceFailure.missingProfile
      }
      try draft.profiles[index].toggleLine(number, expectedDigest: expectedDigest)
    }
  }

  @discardableResult
  public func duplicate(_ id: UUID, name: String) -> UUID? {
    let newID = UUID()
    let succeeded = change { draft in
      guard let index = draft.profiles.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceFailure.missingProfile
      }
      let original = draft.profiles[index]
      draft.profiles.insert(
        Profile(id: newID, name: name, folderID: original.folderID, source: original.source),
        at: index + 1)
    }
    return succeeded ? newID : nil
  }

  public func delete(_ id: UUID) {
    change { try $0.deleteProfile(id) }
  }

  public func restore(_ id: UUID) {
    change { try $0.restoreProfile(id) }
  }

  public func move(_ id: UUID, by offset: Int) {
    change { draft in
      guard let index = draft.profiles.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceFailure.missingProfile
      }
      let siblings = draft.profiles.indices.filter {
        draft.profiles[$0].folderID == draft.profiles[index].folderID
      }
      guard let position = siblings.firstIndex(of: index) else { return }
      let (destination, overflow) = position.addingReportingOverflow(offset)
      guard !overflow, siblings.indices.contains(destination) else { return }
      draft.profiles.insert(draft.profiles.remove(at: index), at: siblings[destination])
    }
  }

  @discardableResult
  public func createFolder(name: String, parentID: UUID? = nil) -> UUID? {
    let folder = ProfileFolder(name: name, parentID: parentID)
    return change { $0.folders.append(folder) } ? folder.id : nil
  }

  public func renameFolder(_ id: UUID, name: String) {
    change { draft in
      guard let index = draft.folders.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceFailure.invalidFolder
      }
      draft.folders[index].name = name
    }
  }

  public func moveToFolder(_ id: UUID, folderID: UUID?) {
    update(id) { $0.folderID = folderID }
  }

  /// Workspace validation rejects cycles, missing parents and excessive nesting atomically.
  public func reparentFolder(_ id: UUID, parentID: UUID?) {
    change { draft in
      guard let index = draft.folders.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceFailure.invalidFolder
      }
      draft.folders[index].parentID = parentID
    }
  }

  public func moveFolder(_ id: UUID, by offset: Int) {
    change { draft in
      guard let index = draft.folders.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceFailure.invalidFolder
      }
      let siblings = draft.folders.indices.filter {
        draft.folders[$0].parentID == draft.folders[index].parentID
      }
      guard let position = siblings.firstIndex(of: index) else { return }
      let (destination, overflow) = position.addingReportingOverflow(offset)
      guard !overflow, siblings.indices.contains(destination) else { return }
      draft.folders.swapAt(index, siblings[destination])
    }
  }

  /// Removing an organizational folder preserves every profile and child folder.
  /// Children and live profiles move to its parent; trashed profiles restore safely at root.
  public func removeFolder(_ id: UUID) {
    change { draft in
      guard let folder = draft.folders.first(where: { $0.id == id }) else {
        throw WorkspaceFailure.invalidFolder
      }
      for index in draft.profiles.indices where draft.profiles[index].folderID == id {
        guard draft.profiles[index].revision < UInt64.max else {
          throw WorkspaceFailure.revisionOverflow
        }
        draft.profiles[index].folderID = folder.parentID
        draft.profiles[index].revision += 1
      }
      for index in draft.folders.indices where draft.folders[index].parentID == id {
        draft.folders[index].parentID = folder.parentID
      }
      draft.folders.removeAll { $0.id == id }
    }
  }

  public func clearEditFailure() { editFailure = nil }

  private func update(_ id: UUID, mutation: (inout Profile) throws -> Void) {
    change { draft in
      guard let index = draft.profiles.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceFailure.missingProfile
      }
      var profile = draft.profiles[index]
      try mutation(&profile)
      guard profile != draft.profiles[index] else { return }
      guard profile.revision < UInt64.max else { throw WorkspaceFailure.revisionOverflow }
      profile.revision += 1
      draft.profiles[index] = profile
    }
  }

  @discardableResult
  private func change(_ mutation: (inout Workspace) throws -> Void) -> Bool {
    guard !isReadOnly else { return false }
    do {
      var next = workspace
      try mutation(&next)
      guard next != workspace else { return true }
      guard workspace.revision < UInt64.max else { throw WorkspaceFailure.revisionOverflow }
      next.revision = workspace.revision + 1
      // Validate the complete serialized budget before accepting text into the visible draft.
      _ = try next.encoded()
      workspace = next
      editFailure = nil
      saveFailed = false
      queueSave()
      return true
    } catch {
      editFailure = (error as? WorkspaceFailure) ?? .limitExceeded
      return false
    }
  }

  private func queueSave() {
    debounce?.cancel()
    guard saving == nil else { return }
    let delay = delay
    debounce = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self else { return }
      _ = await self.flush()
    }
  }

  /// Joins a current save and drains edits received during I/O. Failure keeps the visible
  /// draft intact. Application termination must wait for this result before exiting.
  public func flush() async -> Bool {
    debounce?.cancel()
    debounce = nil
    if let saving { return await saving.value }
    guard hasUnsavedChanges else { return true }
    guard let autosave, !isReadOnly else { return false }
    isSaving = true
    let task = Task { [self] in
      defer {
        isSaving = false
        saving = nil
      }
      do {
        while workspace != savedDraft {
          let draft = workspace
          try await autosave.schedule(draft, automaticallySave: false)
          try await autosave.flush()
          savedDraft = draft
          persisted = await store.state()
        }
        saveFailed = false
        return true
      } catch {
        persisted = await store.state()
        saveFailed = true
        return false
      }
    }
    saving = task
    return await task.value
  }
}
