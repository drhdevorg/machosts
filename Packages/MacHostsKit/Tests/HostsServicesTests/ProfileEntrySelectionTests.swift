import Foundation
import HostsCore
import Testing

@testable import HostsServices

@Test func entryFilteringKeepsLiteralMatchesAndUnicodeLocations() throws {
  let source =
    "# café 🦊\r\n192.0.2.1 Shop.Example alias # QA[1]\r"
    + HostsSyntax.disabled + "::1 other.example # qa[1]\n# 192.0.2.2 ordinary\ninvalid"
  let document = HostsDocument.parse(Data(source.utf8), context: .profile)
  let all = ProfileEntrySelection(document: document, query: "QA[1]", state: .all)
  #expect(all.rows.map(\.id) == [2, 3])
  #expect(all.rows.map(\.isEnabled) == [true, false])
  #expect((source as NSString).substring(with: all.rows[0].range) == all.rows[0].content)
  #expect((source as NSString).substring(with: all.rows[1].range) == all.rows[1].content)
  #expect(
    ProfileEntrySelection(document: document, query: "ALIAS", state: .enabled).rows.count == 1)
  #expect(
    ProfileEntrySelection(document: document, query: "", state: .disabled).rows.map(\.id) == [3])
  #expect(ProfileEntrySelection(document: document, query: ".*", state: .all).rows.isEmpty)
}

@Test func bulkEntriesPreserveBytesAndRejectPartialChanges() throws {
  let source =
    "# café 🦊\r\n  192.0.2.1 one.example alias\t# comment\r"
    + HostsSyntax.disabled + "::1 two.example\ninvalid\r# 192.0.2.2 ordinary"
  var profile = Profile(name: "Bulk", source: source, isEnabled: true)
  let digest = ContentDigest(Data(source.utf8))
  try profile.setLinesEnabled([2, 3], enabled: false, expectedDigest: digest)
  #expect(
    profile.source
      == source.replacingOccurrences(
        of: "  192.0.2.1", with: HostsSyntax.disabled + "  192.0.2.1"))
  #expect(profile.revision == 1 && profile.isEnabled)
  let disabled = profile
  #expect(throws: WorkspaceFailure.staleRevision) {
    try profile.setLinesEnabled([2, 3], enabled: true, expectedDigest: digest)
  }
  #expect(profile == disabled)
  let current = ContentDigest(Data(profile.source.utf8))
  for numbers: Set<Int> in [[2, 4], [2, 5], [2, 99]] {
    #expect(throws: WorkspaceFailure.notAnEntry) {
      try profile.setLinesEnabled(numbers, enabled: true, expectedDigest: current)
    }
    #expect(profile == disabled)
  }
  try profile.setLinesEnabled([2, 3], enabled: false, expectedDigest: current)
  #expect(profile == disabled)
  try profile.setLinesEnabled([2, 3], enabled: true, expectedDigest: current)
  #expect(profile.source == source.replacingOccurrences(of: HostsSyntax.disabled, with: ""))
  #expect(profile.revision == 2)
  profile.kind = .remote
  let remote = profile
  #expect(throws: WorkspaceFailure.readOnlyProfile) {
    try profile.setLinesEnabled(
      [], enabled: true, expectedDigest: ContentDigest(Data(profile.source.utf8)))
  }
  #expect(profile == remote)
}

@Test func bulkEntriesRespectByteLineAndRevisionLimits() throws {
  let first = "192.0.2.1 limit.example\n# "
  var profile = Profile(
    name: "Limit",
    source: first + String(repeating: "x", count: HostsLimits.profileBytes - first.utf8.count))
  let original = profile
  #expect(throws: WorkspaceFailure.limitExceeded) {
    try profile.setLinesEnabled(
      [1], enabled: false, expectedDigest: ContentDigest(Data(profile.source.utf8)))
  }
  #expect(profile == original)
  profile.source =
    "192.0.2.1 limit.example\n" + String(repeating: "\n", count: HostsLimits.systemLines)
  let tooMany = profile
  #expect(throws: WorkspaceFailure.limitExceeded) {
    try profile.setLinesEnabled(
      [1], enabled: false, expectedDigest: ContentDigest(Data(profile.source.utf8)))
  }
  #expect(profile == tooMany)
  profile.source = "192.0.2.1 limit.example"
  profile.revision = UInt64.max
  let exhausted = profile
  #expect(throws: WorkspaceFailure.revisionOverflow) {
    try profile.setLinesEnabled(
      [1], enabled: false, expectedDigest: ContentDigest(Data(profile.source.utf8)))
  }
  #expect(profile == exhausted)
}

@Test @MainActor func bulkEntryActionsPersistAllMatchesAndRejectStaleSnapshots() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "machosts-bulk-" + UUID().uuidString)
  defer {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Bulk fixture cleanup failed")
    }
  }
  var changed = Workspace()
  do {
    let store = try await WorkspaceStore.open(directory: directory)
    let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
    let id = try #require(model.create(name: "Bulk"))
    let source = (1...250).map { "192.0.2.1 host\($0).example\r\n" }.joined()
    model.setSource(id, source: source)
    let selected = ProfileEntrySelection(
      document: HostsDocument.parse(Data(source.utf8), context: .profile), query: "",
      state: .enabled)
    let revision = model.workspace.revision
    model.setLinesEnabled(
      id, numbers: Set(selected.rows.map(\.id)), enabled: false, expectedDigest: selected.digest)
    #expect(model.workspace.revision == revision + 1)
    changed = model.workspace
    #expect(
      HostsDocument.parse(Data(changed.profiles[0].source.utf8), context: .profile).lines.allSatisfy
      {
        if case .entry(let entry) = $0.kind { return !entry.isEnabled }
        return false
      })
    model.setLinesEnabled(id, numbers: [1], enabled: true, expectedDigest: selected.digest)
    #expect(model.workspace == changed && model.editFailure == .staleRevision)
    #expect(await model.flush())
  }
  let reopened = try await WorkspaceStore.open(directory: directory)
  #expect(await reopened.state().snapshot?.draft == changed)
  #expect(await reopened.state().snapshot?.applied == nil)
  #expect(await reopened.state().snapshot?.pendingApply == nil)
}
