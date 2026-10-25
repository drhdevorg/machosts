import Foundation
import HostsCore
import Testing

@Test(arguments: [
  "", "# Kommentar 😀\r\n127.0.0.1 localhost\n\n", "::1 localhost\r",
  "203.0.113.7 A.example. alias # ü", "# SwitchHosts BEGIN\n\t# untouched\n",
])
func losslessLines(_ source: String) {
  let data = Data(source.utf8)
  let document = HostsDocument.parse(data, context: .system)
  let sliced = (Data([32, 32]) + data).dropFirst(2)
  let fromSlice = HostsDocument.parse(sliced, context: .system)
  #expect(fromSlice.data.startIndex == 0)
  #expect(fromSlice == document)
  #expect(document.diagnostics.isEmpty)
  #expect(document.lines.reduce(into: Data()) { $0.append(data.subdata(in: $1.bytes)) } == data)
  #expect(document.lines.map { $0.content + $0.ending }.joined() == source)
}

@Test(arguments: [
  "127.0.0.999 x", "01.2.3.4 x", "::ffff:01.2.3.4 x", "1.2.3 x", "[::1] x", "fe80::1%en0 x",
  "::1:443: x", "127.0.0.1",
  "127.0.0.1 https://x", "127.0.0.1 a:80", "127.0.0.1 *.x", "127.0.0.1 müller.de", "127.0.0.1 a..b",
  "127.0.0.1 -x", "127.0.0.1 x_", "127.0.0.1 x\0", "# hi\u{7f}", "# hi\u{85}",
  "# machosts-disabled: # comment", "# >>> MacHosts managed block v2 >>>",
  "# comment # >>> MacHosts managed block v1 >>>",
])
func rejectsInvalidProfile(_ source: String) {
  #expect(!HostsDocument.parse(Data(source.utf8), context: .profile).diagnostics.isEmpty)
}

@Test func hostnameAndAddressNormalization() throws {
  let document = HostsDocument.parse(
    Data("2001:0DB8:0:0::1 XN--BCHER-KVA.example. local\n".utf8), context: .profile)
  #expect(document.diagnostics.isEmpty)
  guard case .entry(let entry) = try #require(document.lines.first).kind else {
    Issue.record("Expected entry")
    return
  }
  #expect(entry.address.canonical == "2001:db8::1")
  #expect(entry.hostnames == ["xn--bcher-kva.example", "local"])
  #expect(HostsDocument.normalizeHostname(String(repeating: "a", count: 63)) != nil)
  #expect(HostsDocument.normalizeHostname(String(repeating: "a", count: 64)) == nil)
  let maximum = [63, 63, 63, 61].map { String(repeating: "a", count: $0) }.joined(separator: ".")
  #expect(HostsDocument.normalizeHostname(maximum + ".") != nil)
  #expect(HostsDocument.normalizeHostname(maximum + "a") == nil)
  #expect(IPAddress("::ffff:192.0.2.1")?.family == .ipv6)
}

@Test func encodingAndLimits() {
  #expect(
    HostsDocument.parse(Data([255]), context: .system).diagnostics.first?.code
      == .unsupportedEncoding)
  #expect(
    HostsDocument.parse(Data("\u{feff}#x".utf8), context: .system).diagnostics.first?.code
      == .unsupportedEncoding)
  #expect(
    HostsDocument.parse(Data(repeating: 32, count: HostsLimits.profileBytes + 1), context: .profile)
      .diagnostics.first?.code == .sizeLimit)
  #expect(
    HostsDocument.parse(Data(repeating: 10, count: HostsLimits.systemLines + 1), context: .system)
      .diagnostics.first?.code == .lineLimit)
}

private let brokenMarkerFixtures: [String] = [
  [HostsSyntax.begin], [HostsSyntax.end], [HostsSyntax.end, HostsSyntax.begin],
  [HostsSyntax.begin, HostsSyntax.begin, HostsSyntax.end],
  [HostsSyntax.begin, HostsSyntax.end, HostsSyntax.end],
  [HostsSyntax.begin, HostsSyntax.end, HostsSyntax.begin, HostsSyntax.end],
].map { $0.joined(separator: "\n") }

@Test(arguments: brokenMarkerFixtures)
func brokenMarkersBlockPlanning(_ source: String) {
  #expect(throws: (any Error).self) {
    try ApplyPlan.prepare(workspace: Workspace(), system: Data(source.utf8))
  }
}

@Test func profileToggleUsesFreshBytesAndPreservesUndoText() throws {
  let original = "# ordinary\r\n\t203.0.113.1 a b # 😀\r\n\n::1 a"
  var profile = Profile(name: "Test", source: original)
  let digest = ContentDigest(Data(original.utf8))
  try profile.toggleLine(2, expectedDigest: digest)
  #expect(profile.source == "# ordinary\r\n# machosts-disabled: \t203.0.113.1 a b # 😀\r\n\n::1 a")
  #expect(throws: WorkspaceFailure.staleRevision) {
    try profile.toggleLine(2, expectedDigest: digest)
  }
  try profile.toggleLine(2, expectedDigest: ContentDigest(Data(profile.source.utf8)))
  #expect(profile.source == original)
  #expect(throws: WorkspaceFailure.notAnEntry) { try profile.toggleLine(1, expectedDigest: digest) }
  profile.kind = .remote
  #expect(throws: WorkspaceFailure.readOnlyProfile) {
    try profile.toggleLine(2, expectedDigest: digest)
  }
  #expect(
    HostsDocument.parse(Data((HostsSyntax.disabled + "203.0.113.1 a").utf8), context: .system).lines
      .first?.kind == .comment)
}

@Test func deterministicCompositionOriginsAndPreview() throws {
  let a = Profile(
    name: "A",
    source:
      "203.0.113.1 A.example a.example. alias # note\n::1 a.example\n# machosts-disabled: 203.0.113.2 a.example",
    isEnabled: true)
  let b = Profile(name: "B", source: "203.0.113.1 ALIAS other", isEnabled: true)
  let workspace = Workspace(profiles: [a, b, Profile(name: "Off", source: "invalid")])
  let plan = try ApplyPlan.prepare(
    workspace: workspace, system: Data("# foreign\r\n127.0.0.1 localhost\r\n".utf8))
  #expect(plan.mappings.count == 4)
  #expect(plan.mappings.first(where: { $0.hostname == "alias" })?.origins.count == 2)
  #expect(plan.added.count == 4)
  #expect(plan.removed.isEmpty)
  #expect(
    String(decoding: plan.after, as: UTF8.self).contains("203.0.113.1 a.example alias # note"))
  let repeated = try ApplyPlan.prepare(workspace: workspace, system: plan.after)
  #expect(repeated.after == plan.after)
  #expect(repeated.added.isEmpty && repeated.removed.isEmpty)
  if case .noChange = repeated.operation {} else { Issue.record("Expected no-op") }
  #expect(try plan.isCurrent(workspace: workspace, system: plan.before))
  var changed = workspace
  changed.profiles[0].name = "Renamed without revision bump"
  #expect(try !plan.isCurrent(workspace: changed, system: plan.before))
  #expect(try !plan.isCurrent(workspace: workspace, system: Data()))
}

@Test func conflictsIncludeForeignOriginsAndAddressFamily() throws {
  let profile = Profile(name: "A", source: "203.0.113.1 site\n::1 site", isEnabled: true)
  let workspace = Workspace(profiles: [profile])
  _ = try ApplyPlan.prepare(workspace: workspace, system: Data("203.0.113.1 SITE.\n".utf8))
  do {
    _ = try ApplyPlan.prepare(workspace: workspace, system: Data("203.0.113.2 SITE\n".utf8))
    Issue.record("Expected conflict")
  } catch PlanFailure.conflicts(let conflicts) {
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.family == .ipv4)
    #expect(conflicts.first?.mappings.first?.origins.first?.profileID == nil)
    #expect(conflicts.first?.mappings.last?.origins.first?.profileID == profile.id)
  }
  let conflicting = Workspace(profiles: [
    profile, Profile(name: "B", source: "203.0.113.3 site", isEnabled: true),
  ])
  #expect(throws: (any Error).self) {
    try ApplyPlan.prepare(workspace: conflicting, system: Data())
  }
}

@Test(arguments: [
  "", "# external", "# external\r\n",
  "# SwitchHosts BEGIN\n203.0.113.4 foreign\n# SwitchHosts END\r", "127.0.0.1 localhost\n",
])
func appendAndRemovePreserveForeignBytes(_ prefix: String) throws {
  let profile = Profile(name: "Staging", source: "203.0.113.1 stage", isEnabled: true)
  let original = Data(prefix.utf8)
  let plan = try ApplyPlan.prepare(workspace: Workspace(profiles: [profile]), system: original)
  let sliced = (Data([32, 32]) + plan.after).dropFirst(2)
  let removed = try ApplyPlan.prepare(
    workspace: Workspace(), system: sliced, separatorEvidence: plan.separatorEvidence)
  #expect(removed.after == original)
  let withoutProof = try ApplyPlan.prepare(workspace: Workspace(), system: plan.after)
  #expect(withoutProof.after == original || withoutProof.after == original + Data([10]))
}

@Test func replaceMiddleBlockAndStaleOwnership() throws {
  let prefix = Data("# foreign 😀\r\n127.0.0.1 localhost\n".utf8)
  let suffix = Data("# suffix\r203.0.113.4 external".utf8)
  let original =
    prefix + Data((HostsSyntax.begin + "\r\n203.0.113.1 old\r\n" + HostsSyntax.end + "\r\n").utf8)
    + suffix
  let plan = try ApplyPlan.prepare(
    workspace: Workspace(profiles: [
      Profile(name: "New", source: "203.0.113.2 new", isEnabled: true)
    ]), system: original)
  #expect(plan.after.starts(with: prefix))
  #expect(plan.after.suffix(suffix.count) == suffix)
  #expect(plan.removed.map(\.hostname) == ["old"])
  let removed = try ApplyPlan.prepare(workspace: Workspace(), system: plan.after)
  #expect(removed.after == prefix + suffix)
  #expect(throws: PlanFailure.managedBlockChanged) {
    try ApplyPlan.prepare(
      workspace: Workspace(), system: plan.after, expectedManagedDigest: ContentDigest(Data()))
  }
}

@Test func invalidWorkspaceAndResultLimits() throws {
  for name in ["", "bad\nname", "bad\rname", "bad\u{2028}name", HostsSyntax.begin] {
    #expect(throws: WorkspaceFailure.invalidName) {
      try Workspace(profiles: [Profile(name: name)]).validate()
    }
  }
  let profile = Profile(name: "A")
  #expect(throws: WorkspaceFailure.duplicateID) {
    try Workspace(profiles: [profile, profile]).validate()
  }
  let folderID = UUID()
  #expect(throws: WorkspaceFailure.invalidFolder) {
    try Workspace(folders: [.init(id: folderID, name: "Cycle", parentID: folderID)]).validate()
  }
  let active = Profile(name: "A", source: "203.0.113.1 x", isEnabled: true)
  #expect(throws: PlanFailure.resultLimitExceeded) {
    try ApplyPlan.prepare(
      workspace: Workspace(profiles: [active]),
      system: Data(repeating: 10, count: HostsLimits.systemLines))
  }
  var workspace = Workspace(profiles: [active])
  try workspace.deleteProfile(active.id)
  #expect(workspace.profiles.isEmpty && workspace.trash.count == 1)
  try workspace.restoreProfile(active.id)
  #expect(workspace.profiles.first?.isEnabled == false)
  #expect(try JSONDecoder().decode(Workspace.self, from: workspace.encoded()) == workspace)
  let digest = ContentDigest(Data("abc".utf8))
  #expect(digest.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  #expect(
    try JSONDecoder().decode(ContentDigest.self, from: JSONEncoder().encode(digest)) == digest)
}

@Test func generatedForeignBytePreservation() throws {
  // Deterministic generated comments/line endings; no file I/O or random flaky fixture.
  for seed in 0..<100 {
    let prefix = (0..<(seed % 9)).map {
      "# foreign \(seed)-\($0) ü" + (["\n", "\r\n", "\r"][($0 + seed) % 3])
    }.joined()
    let suffix = "# suffix \(seed)" + (seed % 2 == 0 ? "\r\n" : "")
    let middle = HostsSyntax.begin + "\n203.0.113.1 old\n" + HostsSyntax.end + "\n"
    let removed = try ApplyPlan.prepare(
      workspace: Workspace(), system: Data((prefix + middle + suffix).utf8))
    #expect(removed.after == Data((prefix + suffix).utf8))
  }
}
