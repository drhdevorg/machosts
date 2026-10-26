import Foundation
import HostsCore
import Testing

@testable import HostsServices

@Test func hostsTextExchangePreservesSourceAndExportsOnlyEnabledRecords() async throws {
  let service = HostsTextExchange()
  let source =
    "# café 😀\r\n192.0.2.1 SHOP.example alias # note\r\n"
    + HostsSyntax.disabled + "::1 off.example\r\n\r\n2001:db8::1 v6.example"
  let imported = try HostsTextImport(data: Data(source.utf8))
  #expect(imported.source == source)
  #expect(imported.document.diagnostics.isEmpty)
  #expect(try await service.data(source: source, mode: .source) == Data(source.utf8))
  #expect(
    try await service.data(source: source, mode: .enabledEntries)
      == Data("192.0.2.1 SHOP.example alias # note\r\n2001:db8::1 v6.example".utf8))
  #expect(try await service.data(source: "# comment", mode: .enabledEntries).isEmpty)
}

@Test func hostsTextExchangeRejectsPartialInputsButPreservesInvalidDrafts() async throws {
  let service = HostsTextExchange()
  for data in [Data([0xff]), Data([0xef, 0xbb, 0xbf]) + Data("# text".utf8)] {
    #expect(throws: HostsTextExchangeFailure.unsupportedEncoding) {
      try HostsTextImport(data: data)
    }
  }
  #expect(throws: HostsTextExchangeFailure.sizeLimit) {
    try HostsTextImport(data: Data(repeating: 32, count: HostsLimits.profileBytes + 1))
  }
  #expect(throws: HostsTextExchangeFailure.incompleteDocument) {
    try HostsTextImport(
      data: Data(String(repeating: "\n", count: HostsLimits.systemLines + 1).utf8))
  }
  let source = "not an address\n" + HostsSyntax.begin + "\n"
  #expect(try HostsTextImport(data: Data(source.utf8)).document.diagnostics.count == 2)
  #expect(try await service.data(source: source, mode: .source) == Data(source.utf8))
  await #expect(throws: HostsTextExchangeFailure.invalidEntries) {
    try await service.data(source: source, mode: .enabledEntries)
  }
  // Original source is also an escape path for drafts the parser cannot fully display.
  let longSource = String(repeating: "\n", count: HostsLimits.systemLines + 1)
  #expect(try await service.data(source: longSource, mode: .source) == Data(longSource.utf8))
}

@Test func hostsTextExchangeUsesBoundedFilesAndNeverOverwritesLinks() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Cleanup failed")
    }
  }
  let service = HostsTextExchange()
  let file = directory.appendingPathComponent("fixture.hosts")
  let bytes = Data("# private fixture\r\n192.0.2.1 test.example".utf8)
  try await service.writeNew(bytes, to: file)
  #expect(try await service.read(file).source == String(decoding: bytes, as: UTF8.self))
  let link = directory.appendingPathComponent("link.hosts")
  let hardlink = directory.appendingPathComponent("hardlink.hosts")
  let dangling = directory.appendingPathComponent("dangling.hosts")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
  try FileManager.default.linkItem(at: file, to: hardlink)
  try FileManager.default.createSymbolicLink(
    at: dangling, withDestinationURL: directory.appendingPathComponent("missing"))
  for target in [file, link, hardlink, dangling] {
    await #expect(throws: HostsTextExchangeFailure.destinationExists) {
      try await service.writeNew(Data("changed".utf8), to: target)
    }
  }
  #expect(try Data(contentsOf: file) == bytes)
  await #expect(throws: HostsTextExchangeFailure.unreadable) { try await service.read(directory) }
  let oversized = directory.appendingPathComponent("oversized.hosts")
  try Data(repeating: 32, count: HostsLimits.profileBytes + 1).write(to: oversized)
  await #expect(throws: HostsTextExchangeFailure.sizeLimit) { try await service.read(oversized) }
  let boundary = directory.appendingPathComponent("boundary.hosts")
  let boundaryBytes = Data(("#" + String(repeating: "x", count: HostsLimits.profileBytes - 1)).utf8)
  try await service.writeNew(boundaryBytes, to: boundary)
  #expect(try await service.read(boundary).source.utf8.count == HostsLimits.profileBytes)
}

@Test @MainActor func hostsTextImportIsAtomicInactiveAndPersistsExactReviewedBytes() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Cleanup failed")
    }
  }
  do {
    let store = try await WorkspaceStore.open(directory: directory)
    let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
    let original = try #require(model.create(name: "Existing"))
    model.setEnabled(original, enabled: true)
    let snapshot = try HostsTextImport(data: Data("# 日本語\r\ninvalid draft\r\n".utf8))
    let before = model.workspace
    #expect(model.importText(snapshot, name: "\n") == nil)
    #expect(model.workspace == before)
    let id = try #require(model.importText(snapshot, name: "Existing"))
    let added = try #require(model.workspace.profiles.last)
    #expect(id != original && added.id == id && added.kind == .local && !added.isEnabled)
    #expect(added.source == snapshot.source && added.folderID == nil)
    #expect(model.workspace.revision == before.revision + 1)
    #expect(model.workspace.profiles.first?.isEnabled == true)
    #expect(await model.flush())
    #expect(model.persisted.snapshot?.pendingApply == nil)
    #expect(model.persisted.snapshot?.applied == nil)
  }
  let reopened = try await WorkspaceStore.open(directory: directory)
  #expect(
    await reopened.state().snapshot?.draft.profiles.last?.source == "# 日本語\r\ninvalid draft\r\n")
}

@Test @MainActor func hostsTextImportRespectsCombinedLiveTrashLimit() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Cleanup failed")
    }
  }
  let store = try await WorkspaceStore.open(directory: directory)
  let workspace = Workspace(
    revision: 1, profiles: (0..<499).map { Profile(name: "Profile \($0)") },
    trash: [.init(profile: Profile(name: "Deleted"), formerIndex: 0)])
  _ = try await store.saveDraft(workspace, expectedGeneration: 0)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let snapshot = try HostsTextImport(data: Data("192.0.2.1 new.example".utf8))
  #expect(model.importText(snapshot, name: "Imported") == nil)
  #expect(model.editFailure == .limitExceeded)
  #expect(model.workspace == workspace && !model.hasUnsavedChanges)
  #expect(await store.state().snapshot?.draft == workspace)
}
