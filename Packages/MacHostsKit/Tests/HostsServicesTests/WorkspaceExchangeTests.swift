import Foundation
import HostsCore
import Testing

@testable import HostsServices

@Test func jsonExchangeRoundtripRemapsHierarchyAndOmitsRuntimeState() throws {
  let root = ProfileFolder(name: "Root")
  let child = ProfileFolder(name: "Child", parentID: root.id)
  let source = "# café 😀\r\n192.0.2.1 example.test\r\ninvalid draft"
  let profile = Profile(
    name: "Same name", folderID: child.id, kind: .remote,
    source: source, isEnabled: true, revision: 99)
  let original = Workspace(
    revision: 50, profiles: [profile], folders: [root, child],
    trash: [.init(profile: Profile(name: "Deleted secret", source: "# omitted"), formerIndex: 0)])
  let document = try WorkspaceExchangeDocument(workspace: original)
  let bytes = try document.encoded()
  let json = String(decoding: bytes, as: UTF8.self)
  for omitted in ["Deleted secret", "isEnabled", "revision", "receipt", "pendingApply", "kind"] {
    #expect(!json.contains(omitted))
  }
  #expect(try document.encoded() == bytes)
  let decoded = try WorkspaceExchangeDocument(data: bytes)
  let merged = try decoded.appending(to: original)
  #expect(merged.profiles.first == profile)
  #expect(merged.trash == original.trash)
  let imported = try #require(merged.profiles.last)
  #expect(imported.id != profile.id)
  #expect(imported.source == source)
  #expect(!imported.isEnabled && imported.kind == .local && imported.revision == 0)
  #expect(merged.folders.count == 4)
  #expect(imported.folderID == merged.folders[3].id)
  #expect(merged.folders[3].parentID == merged.folders[2].id)
  #expect(merged.folders[2].parentID == nil)
  let twice = try decoded.appending(to: merged)
  #expect(Set(twice.profiles.map(\.id)).count == 3)
  #expect(Set(twice.folders.map(\.id)).count == 6)
}

@Test func jsonExchangeRejectsUnsupportedCorruptAndInvalidGraphs() throws {
  let folder = ProfileFolder(name: "Root")
  let profile = Profile(name: "Valid", folderID: folder.id, source: "192.0.2.1 a.test")
  let bytes = try WorkspaceExchangeDocument(
    workspace: Workspace(profiles: [profile], folders: [folder])
  ).encoded()
  let text = String(decoding: bytes, as: UTF8.self)
  #expect(throws: WorkspaceExchangeFailure.unsupportedVersion) {
    try WorkspaceExchangeDocument(
      data: Data(text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2").utf8))
  }
  for malformed in [
    "{}", "{", text.replacingOccurrences(of: "MacHosts", with: "Other"),
    text.replacingOccurrences(of: "\"parentID\"", with: "\"unused\"")
      .replacingOccurrences(of: "\"name\" : \"Root\"", with: "\"name\" : \"\""),
    text.replacingOccurrences(of: profile.id.uuidString, with: folder.id.uuidString),
    text.replacingOccurrences(
      of: folder.id.uuidString, with: UUID().uuidString, options: [],
      range: text.range(of: folder.id.uuidString)),
  ] {
    #expect(throws: WorkspaceExchangeFailure.invalidDocument) {
      try WorkspaceExchangeDocument(data: Data(malformed.utf8))
    }
  }
  #expect(throws: HostsTextExchangeFailure.sizeLimit) {
    try WorkspaceExchangeDocument(data: Data(repeating: 32, count: HostsLimits.workspaceBytes + 1))
  }
  let full = Workspace(profiles: (0..<HostsLimits.profiles).map { Profile(name: "P\($0)") })
  let document = try WorkspaceExchangeDocument(data: bytes)
  #expect(throws: WorkspaceFailure.limitExceeded) { try document.appending(to: full) }
  #expect(full.profiles.count == HostsLimits.profiles)
}

@Test func jsonExchangeRejectsIncompleteSourcesAndOversizedSerializedExports() throws {
  let long = Workspace(profiles: [
    Profile(name: "Long", source: String(repeating: "\n", count: HostsLimits.systemLines + 1))
  ])
  #expect(throws: HostsTextExchangeFailure.incompleteDocument) {
    try WorkspaceExchangeDocument(workspace: long)
  }
  // Escaped JSON bytes count against the complete workspace budget.
  let source = String(repeating: "\t", count: HostsLimits.profileBytes)
  let many = Workspace(profiles: (0..<17).map { Profile(name: "P\($0)", source: source) })
  #expect(throws: WorkspaceFailure.limitExceeded) {
    try WorkspaceExchangeDocument(workspace: many).encoded()
  }
}

@Test func jsonExchangeFilesAreBoundedAndExclusive() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Cleanup failed")
    }
  }
  let service = WorkspaceExchange()
  let document = try WorkspaceExchangeDocument(workspace: Workspace(profiles: [Profile(name: "A")]))
  let url = directory.appendingPathComponent("exchange.json")
  try await service.writeNew(document, to: url)
  #expect(try await service.read(url).profiles.count == 1)
  let link = directory.appendingPathComponent("link.json")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
  for destination in [url, link] {
    await #expect(throws: HostsTextExchangeFailure.destinationExists) {
      try await service.writeNew(document, to: destination)
    }
  }
  await #expect(throws: HostsTextExchangeFailure.unreadable) { try await service.read(directory) }
  let large = directory.appendingPathComponent("large.json")
  try Data(repeating: 32, count: HostsLimits.workspaceBytes + 1).write(to: large)
  await #expect(throws: HostsTextExchangeFailure.sizeLimit) { try await service.read(large) }
}

@Test @MainActor func jsonImportPublishesOneRevisionAndPersistsWithoutApply() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Cleanup failed")
    }
  }
  let folder = ProfileFolder(name: "Imported")
  let incoming = Workspace(
    profiles: [
      Profile(
        name: "Same", folderID: folder.id,
        source: "# 日本語\r\ninvalid draft", isEnabled: true)
    ], folders: [folder])
  let document = try WorkspaceExchangeDocument(workspace: incoming)
  do {
    let store = try await WorkspaceStore.open(directory: directory)
    let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
    let existing = try #require(model.create(name: "Same"))
    model.setEnabled(existing, enabled: true)
    let before = model.workspace
    #expect(model.importWorkspace(document))
    #expect(model.workspace.revision == before.revision + 1)
    #expect(model.workspace.profiles.first == before.profiles.first)
    #expect(model.workspace.profiles.last?.isEnabled == false)
    #expect(model.workspace.profiles.last?.source == incoming.profiles[0].source)
    #expect(await model.flush())
    #expect(model.persisted.snapshot?.pendingApply == nil)
    #expect(model.persisted.snapshot?.applied == nil)
  }
  let reopened = try await WorkspaceStore.open(directory: directory)
  #expect(await reopened.state().snapshot?.draft.profiles.count == 2)
  #expect(await reopened.state().snapshot?.draft.folders.count == 1)
}

@Test @MainActor func jsonImportBudgetFailurePreservesEntireDraft() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Cleanup failed")
    }
  }
  let store = try await WorkspaceStore.open(directory: directory)
  let full = Workspace(
    revision: 1, profiles: (0..<499).map { Profile(name: "P\($0)") },
    trash: [.init(profile: Profile(name: "Deleted"), formerIndex: 0)])
  _ = try await store.saveDraft(full, expectedGeneration: 0)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let incoming = try WorkspaceExchangeDocument(
    workspace: Workspace(
      profiles: [Profile(name: "New")],
      folders: [ProfileFolder(name: "New folder")]))
  #expect(!model.importWorkspace(incoming))
  #expect(model.workspace == full && !model.hasUnsavedChanges)
  #expect(await store.state().snapshot?.draft == full)
}

@Test func jsonVersionOneLiteralFixtureAndCyclicFolderRejection() throws {
  // Independent fixed wire fixture: do not derive it through the product encoder.
  let fixture = #"""
    {"format":"MacHosts","version":1,
     "folders":[{"id":"00000000-0000-0000-0000-000000000001","name":"Staging"}],
     "profiles":[{"id":"00000000-0000-0000-0000-000000000002","name":"Shop",
       "folderID":"00000000-0000-0000-0000-000000000001",
       "source":"# café 😀\r\n192.0.2.42 shop.example\r\n"}]}
    """#
  let document = try WorkspaceExchangeDocument(data: Data(fixture.utf8))
  #expect(document.profiles[0].source == "# café 😀\r\n192.0.2.42 shop.example\r\n")
  #expect(try WorkspaceExchangeDocument(data: document.encoded()).profiles[0].name == "Shop")
  let cycle = fixture.replacingOccurrences(
    of: "\"name\":\"Staging\"",
    with: "\"name\":\"Staging\",\"parentID\":\"00000000-0000-0000-0000-000000000001\"")
  #expect(throws: WorkspaceExchangeFailure.invalidDocument) {
    try WorkspaceExchangeDocument(data: Data(cycle.utf8))
  }
}

@Test func jsonSelectionPreservesOrderedSourcesAndOnlyRequiredAncestors() throws {
  let root = ProfileFolder(name: "Root")
  let child = ProfileFolder(name: "Child", parentID: root.id)
  let empty = ProfileFolder(name: "Empty", parentID: root.id)
  let unrelated = ProfileFolder(name: "Unrelated")
  let first = Profile(name: "First", folderID: child.id, source: "# café\r\ninvalid draft")
  let excluded = Profile(name: "Excluded", folderID: unrelated.id)
  let last = Profile(name: "Last", folderID: child.id, source: "192.0.2.3 last.test")
  let document = try WorkspaceExchangeDocument(
    workspace: Workspace(
      profiles: [first, excluded, last], folders: [unrelated, child, root, empty]))
  let selected = try document.selecting(profileIDs: [last.id, first.id], includeAllFolders: false)
  #expect(selected.profiles.map(\.id) == [first.id, last.id])
  #expect(selected.profiles.map(\.source) == [first.source, last.source])
  #expect(selected.folders.map(\.id) == [child.id, root.id])
  let decoded = try WorkspaceExchangeDocument(data: selected.encoded())
  let imported = try decoded.appending(to: Workspace())
  #expect(imported.profiles.map(\.name) == ["First", "Last"])
  #expect(imported.profiles.allSatisfy { !$0.isEnabled && $0.kind == .local })
  #expect(imported.profiles[0].folderID == imported.folders[0].id)
  #expect(imported.folders[0].parentID == imported.folders[1].id)
  #expect(document.profiles.count == 3 && document.folders.count == 4)
}

@Test func jsonSelectionSupportsEmptyFoldersAndRejectsUnknownIdentities() throws {
  let folder = ProfileFolder(name: "Empty")
  let profile = Profile(name: "Root profile")
  let document = try WorkspaceExchangeDocument(
    workspace: Workspace(
      profiles: [profile], folders: [folder]))
  let foldersOnly = try document.selecting(profileIDs: [], includeAllFolders: true)
  #expect(foldersOnly.profiles.isEmpty && foldersOnly.folders.map(\.id) == [folder.id])
  let nothing = try document.selecting(profileIDs: [], includeAllFolders: false)
  #expect(nothing.profiles.isEmpty && nothing.folders.isEmpty)
  let rootOnly = try document.selecting(profileIDs: [profile.id], includeAllFolders: false)
  #expect(rootOnly.profiles.count == 1 && rootOnly.folders.isEmpty)
  for id in [UUID(), folder.id] {
    #expect(throws: WorkspaceExchangeFailure.invalidDocument) {
      try document.selecting(profileIDs: [profile.id, id], includeAllFolders: true)
    }
  }
}

@Test @MainActor func jsonSelectedImportUsesCurrentBudgetAndPersistsOnlySelection() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Cleanup failed")
    }
  }
  let chosen = Profile(name: "Chosen", source: "# preserved\r\n192.0.2.1 chosen.test")
  let omitted = Profile(name: "Omitted")
  let document = try WorkspaceExchangeDocument(workspace: Workspace(profiles: [chosen, omitted]))
  let subset = try document.selecting(profileIDs: [chosen.id], includeAllFolders: false)
  do {
    let store = try await WorkspaceStore.open(directory: directory)
    let full = Workspace(revision: 1, profiles: (0..<499).map { Profile(name: "P\($0)") })
    _ = try await store.saveDraft(full, expectedGeneration: 0)
    let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
    #expect(!model.importWorkspace(document))
    #expect(model.workspace == full)
    #expect(model.importWorkspace(subset))
    let after = model.workspace
    #expect(after.revision == 2 && after.profiles.count == 500)
    #expect(after.profiles.last?.source == chosen.source)
    #expect(!model.importWorkspace(subset))
    #expect(model.workspace == after)
    #expect(await model.flush())
    #expect(model.persisted.snapshot?.applied == nil)
    #expect(model.persisted.snapshot?.pendingApply == nil)
  }
  let store = try await WorkspaceStore.open(directory: directory)
  let draft = try #require(await store.state().snapshot?.draft)
  #expect(draft.profiles.last?.name == "Chosen")
  #expect(!draft.profiles.contains { $0.name == "Omitted" })
}
