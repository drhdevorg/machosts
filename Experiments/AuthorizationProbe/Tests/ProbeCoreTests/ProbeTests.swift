import Darwin
import Foundation
import Testing

@testable import ProbeCore

@Test func requestRoundTrip() throws {
  let request = ProbeRequest(expectedDigest: digest(Data()), operation: .installExample)
  #expect(try ProbeRequest.decode(JSONEncoder().encode(request)) == request)
}

@Test(arguments: [
  #""version":1,"#, #""version":2,"#, #""\u0076ersion":1,"#,
  #""operation":"installExample","#, #""operation":"removeExample","#,
  #""expectedDigest":"bad","#,
  #""transactionID":"00000000-0000-0000-0000-000000000000","#,
])
func rejectsDuplicateRequestKeys(extra: String) throws {
  let request = ProbeRequest(expectedDigest: digest(Data()), operation: .installExample)
  let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
  for injected in [
    "{" + extra + encoded.dropFirst(), String(encoded.dropLast()) + "," + extra.dropLast() + "}",
  ] {
    #expect(throws: ProbeError.invalidRequest) { try ProbeRequest.decode(Data(injected.utf8)) }
  }
}

@Test func acceptsReorderedWhitespaceAndEscapedKeys() throws {
  let id = UUID()
  let input = """
    {
      "operation" : "removeExample",
      "expectedDigest" : "\(digest(Data()))",
      "transactionID" : "\(id.uuidString)",
      "\\u0076ersion" : 1
    }
    """
  let decoded = try ProbeRequest.decode(Data(input.utf8))
  #expect(decoded.transactionID == id)
  #expect(decoded.operation == .removeExample)
}

@Test func rejectsEveryTruncatedRequest() throws {
  let request = ProbeRequest(expectedDigest: digest(Data()), operation: .installExample)
  let encoded = try JSONEncoder().encode(request)
  for length in 0..<encoded.count {
    #expect(throws: ProbeError.invalidRequest) {
      try ProbeRequest.decode(Data(encoded.prefix(length)))
    }
  }
}

@Test(arguments: [
  "", "{}", "[]", "null", "{", #"{"version":1,}"#,
  #"{"version":01}"#, #"{"version":1.0}"#, #"{"version":[]}"#,
  #"{"version":{"version":1}}"#, #"{"version":1}{}"#,
  #"{"operation":"unterminated\"}"#, #"{"operation":"bad\q"}"#,
  #"{"operation":"a\",}b","version":1}"#,
])
func rejectsMalformedRequestEnvelope(input: String) {
  #expect(throws: ProbeError.invalidRequest) { try ProbeRequest.decode(Data(input.utf8)) }
}

@Test(arguments: [
  "\"path\":\"/private/etc/hosts\",", "\"command\":\"id\",", "\"unexpected\":null,",
])
func rejectsExtraRequestFields(extra: String) throws {
  let request = ProbeRequest(expectedDigest: digest(Data()), operation: .installExample)
  let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
  let injected = "{" + extra + encoded.dropFirst()
  #expect(throws: ProbeError.invalidRequest) { try ProbeRequest.decode(Data(injected.utf8)) }
}

@Test func rejectsInvalidAndOversizedRequests() throws {
  #expect(throws: ProbeError.oversized) {
    try ProbeRequest.decode(Data(repeating: 32, count: ProbeRequest.maximumBytes + 1))
  }
  for value in ["bad", String(repeating: "G", count: 64), "$(touch /tmp/machosts-injected)"] {
    let request = ProbeRequest(expectedDigest: value, operation: .installExample)
    #expect(throws: ProbeError.invalidRequest) { try request.validate() }
  }
  let valid = ProbeRequest(expectedDigest: digest(Data()), operation: .installExample)
  let encoded = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
  #expect(throws: ProbeError.invalidRequest) {
    try ProbeRequest.decode(
      Data(encoded.replacingOccurrences(of: "installExample", with: "arbitraryCommand").utf8))
  }
}

@Test func preservesForeignBytesAndRemovesOwnBlock() throws {
  let prefix = Data("127.0.0.1 localhost\r\n# Übergrößenträger '$()'\r\n".utf8)
  let suffix = Data("# foreign suffix without newline".utf8)
  var input = prefix
  input.append(Data(ExampleBlock.content.utf8))
  input.append(suffix)
  let updated = try ExampleBlock.compose(input, operation: .installExample)
  #expect(updated == input)
  var foreign = prefix
  foreign.append(suffix)
  #expect(try ExampleBlock.compose(input, operation: .removeExample) == foreign)
}

@Test func missingFinalNewlineAddsOnlyNecessarySeparator() throws {
  let before = Data("127.0.0.1 localhost".utf8)
  let applied = try ExampleBlock.compose(before, operation: .installExample)
  #expect(applied == before + Data("\n".utf8) + Data(ExampleBlock.content.utf8))
  // Without original seam provenance we deliberately retain this separator on removal.
  #expect(try ExampleBlock.compose(applied, operation: .removeExample) == before + Data("\n".utf8))
}

@Test(arguments: [
  ExampleBlock.start, ExampleBlock.end,
  "\(ExampleBlock.end)\n\(ExampleBlock.start)\n",
  "\(ExampleBlock.start)\n\(ExampleBlock.start)\n\(ExampleBlock.end)\n",
  "\(ExampleBlock.content)\(ExampleBlock.content)",
])
func rejectsAmbiguousMarkers(text: String) {
  #expect(throws: ProbeError.malformedMarkers) {
    try ExampleBlock.compose(Data(text.utf8), operation: .installExample)
  }
}

@Test func applyReadbackAndExactRestore() async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let request = ProbeRequest(expectedDigest: digest(original), operation: .installExample)
  let result = try await session.apply(request)
  #expect(digest(try await session.snapshot()) == result.afterDigest)
  #expect(result.unchanged == false)
  try await session.restoreOriginal(expectedDigest: result.afterDigest)
  #expect(try await session.snapshot() == original)
  try await session.close()
}

@Test func replayWithStaleDigestIsRejected() async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let request = ProbeRequest(expectedDigest: digest(original), operation: .installExample)
  _ = try await session.apply(request)
  let current = try await session.snapshot()
  await #expect(throws: ProbeError.staleRevision) { try await session.apply(request) }
  #expect(try await session.snapshot() == current)
  try await session.close()
}

@Test func noOpNeedsNoBackupOrJournal() async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let request = ProbeRequest(expectedDigest: digest(original), operation: .removeExample)
  let result = try await session.apply(request, failure: .beforeBackup)
  #expect(result.unchanged)
  #expect(try await session.recover() == .clean)
  try await session.close()
}

@Test(arguments: [
  ProbeFailurePoint.beforeBackup, .afterBackup, .afterJournal, .afterReplacement, .afterReceipt,
])
func interruptedCommitCanBeReconstructed(point: ProbeFailurePoint) async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let request = ProbeRequest(expectedDigest: digest(original), operation: .installExample)
  await #expect(throws: ProbeError.injectedFailure) {
    try await session.apply(request, failure: point)
  }
  let outcome = try await session.recover()
  switch point {
  case .none: Issue.record("Unexpected test parameter")
  case .beforeBackup, .afterBackup:
    #expect(outcome == .clean)
    #expect(try await session.snapshot() == original)
  case .afterJournal:
    #expect(outcome == .notCommitted)
    #expect(try await session.snapshot() == original)
  case .afterReplacement, .afterReceipt:
    #expect(outcome == .committed)
    let current = try await session.snapshot()
    try await session.restoreOriginal(expectedDigest: digest(current))
    #expect(try await session.snapshot() == original)
  }
  #expect(try await session.recover() == .clean)
  try await session.close()
}

@Test func recoveryNeverOverwritesExternalChanges() async throws {
  let session = try SandboxSession()
  let request = ProbeRequest(
    expectedDigest: digest(try await session.snapshot()), operation: .installExample)
  await #expect(throws: ProbeError.injectedFailure) {
    try await session.apply(request, failure: .afterReplacement)
  }
  let external = Data("# external edit\n".utf8)
  try external.write(to: await session.fixtureURL())
  #expect(try await session.recover() == .externalChange)
  #expect(try await session.snapshot() == external)
  await #expect(throws: ProbeError.recoveryRequired) { try await session.apply(request) }
  try await session.close()
}

@Test func rejectsSymlinkAndHardlinkTargets() async throws {
  for hardlink in [false, true] {
    let session = try SandboxSession()
    let target = await session.fixtureURL()
    let other = target.deletingLastPathComponent().appendingPathComponent("foreign.fixture")
    try FileManager.default.moveItem(at: target, to: other)
    if hardlink {
      try FileManager.default.linkItem(at: other, to: target)
    } else {
      try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
    }
    let before = try Data(contentsOf: other)
    await #expect(throws: ProbeError.unsafeFile) { try await session.snapshot() }
    #expect(try Data(contentsOf: other) == before)
    try await session.close()
  }
}

@Test(arguments: ["directory", "fifo", "danglingSymlink"])
func rejectsNonRegularFixtures(kind: String) async throws {
  let session = try SandboxSession()
  let target = await session.fixtureURL()
  try FileManager.default.removeItem(at: target)
  switch kind {
  case "directory":
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
  case "fifo":
    let status = target.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return mkfifo(path, 0o600)
    }
    #expect(status == 0)
  default:
    try FileManager.default.createSymbolicLink(
      at: target, withDestinationURL: target.appendingPathExtension("missing"))
  }
  await #expect(throws: ProbeError.unsafeFile) { try await session.snapshot() }
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
      == ["hosts.fixture"])
  try await session.close()
}

@Test(arguments: ["journal.json", "original.bin", "receipt.json"], [false, true])
func rejectsLinkedRecoveryArtifacts(name: String, hardlink: Bool) async throws {
  let session = try SandboxSession()
  let target = await session.fixtureURL()
  let request = ProbeRequest(
    expectedDigest: digest(try await session.snapshot()), operation: .installExample)
  if name == "receipt.json" {
    _ = try await session.apply(request)
  } else {
    await #expect(throws: ProbeError.injectedFailure) {
      try await session.apply(request, failure: .afterReplacement)
    }
  }
  let committed = try await session.snapshot()
  let directory = target.deletingLastPathComponent()
  let artifact = directory.appendingPathComponent(name)
  let foreign = directory.appendingPathComponent("foreign.fixture")
  try FileManager.default.moveItem(at: artifact, to: foreign)
  let before = try Data(contentsOf: foreign)
  if hardlink {
    try FileManager.default.linkItem(at: foreign, to: artifact)
  } else {
    try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: foreign)
  }
  let artifactsBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  if name == "receipt.json" {
    await #expect(throws: ProbeError.unsafeFile) {
      try await session.restoreOriginal(expectedDigest: digest(committed))
    }
  } else {
    await #expect(throws: ProbeError.unsafeFile) { try await session.recover() }
    await #expect(throws: ProbeError.recoveryRequired) { try await session.apply(request) }
  }
  #expect(try await session.snapshot() == committed)
  #expect(try Data(contentsOf: foreign) == before)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == artifactsBefore)
  try await session.close()
}

@Test(arguments: [0, 65_535, 65_536, 65_537, SandboxSession.maximumFileBytes])
func readsFixtureWithinLimitExactly(size: Int) async throws {
  let session = try SandboxSession()
  let content = Data(repeating: 35, count: size)
  try content.write(to: await session.fixtureURL())
  #expect(try await session.snapshot() == content)
  try await session.close()
}

@Test(arguments: [SandboxSession.maximumFileBytes + 1, SandboxSession.maximumFileBytes * 2])
func oversizedFixtureBlocksApplyWithoutArtifacts(size: Int) async throws {
  let session = try SandboxSession()
  let target = await session.fixtureURL()
  let content = Data(repeating: 35, count: size)
  try content.write(to: target)
  await #expect(throws: ProbeError.oversized) { try await session.snapshot() }
  let request = ProbeRequest(expectedDigest: digest(content), operation: .installExample)
  await #expect(throws: ProbeError.oversized) { try await session.apply(request) }
  #expect(try Data(contentsOf: target) == content)
  let artifacts = try FileManager.default.contentsOfDirectory(
    atPath: target.deletingLastPathComponent().path)
  #expect(artifacts == ["hosts.fixture"])
  try await session.close()
}

@Test func oversizedRecoveryBackupPreservesJournalAndTarget() async throws {
  let session = try SandboxSession()
  let target = await session.fixtureURL()
  let request = ProbeRequest(
    expectedDigest: digest(try await session.snapshot()), operation: .installExample)
  await #expect(throws: ProbeError.injectedFailure) {
    try await session.apply(request, failure: .afterReplacement)
  }
  let committed = try await session.snapshot()
  let directory = target.deletingLastPathComponent()
  let journal = directory.appendingPathComponent("journal.json")
  let journalBefore = try Data(contentsOf: journal)
  try Data(repeating: 35, count: SandboxSession.maximumFileBytes + 1)
    .write(to: directory.appendingPathComponent("original.bin"))
  await #expect(throws: ProbeError.oversized) { try await session.recover() }
  #expect(try await session.snapshot() == committed)
  #expect(try Data(contentsOf: journal) == journalBefore)
  await #expect(throws: ProbeError.recoveryRequired) { try await session.apply(request) }
  try await session.close()
}

@Test func oversizedProposedFileIsRejectedBeforeBackup() async throws {
  let session = try SandboxSession()
  let target = await session.fixtureURL()
  let original = Data(repeating: 35, count: SandboxSession.maximumFileBytes)
  try original.write(to: target)
  let request = ProbeRequest(expectedDigest: digest(original), operation: .installExample)
  await #expect(throws: ProbeError.oversized) { try await session.apply(request) }
  #expect(try await session.snapshot() == original)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
      == ["hosts.fixture"])
  try await session.close()
}

@Test(arguments: [
  ProbeFailurePoint.beforeBackup, .afterBackup, .afterJournal, .afterReplacement, .afterReceipt,
])
func interruptedRestoreCanBeReconstructed(point: ProbeFailurePoint) async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let applied = try await session.apply(
    ProbeRequest(expectedDigest: digest(original), operation: .installExample))
  let current = try await session.snapshot()
  let directory = await session.fixtureURL().deletingLastPathComponent()
  let applyReceipt = try Data(contentsOf: directory.appendingPathComponent("receipt.json"))
  await #expect(throws: ProbeError.injectedFailure) {
    try await session.restoreOriginal(expectedDigest: applied.afterDigest, failure: point)
  }
  if point == .afterJournal || point == .afterReplacement || point == .afterReceipt {
    await #expect(throws: ProbeError.recoveryRequired) {
      try await session.restoreOriginal(expectedDigest: digest(try await session.snapshot()))
    }
    await #expect(throws: ProbeError.recoveryRequired) {
      try await session.apply(
        ProbeRequest(
          expectedDigest: digest(try await session.snapshot()), operation: .removeExample))
    }
  }
  let outcome = try await session.recover()
  switch point {
  case .none: Issue.record("Unexpected test parameter")
  case .beforeBackup, .afterBackup:
    #expect(outcome == .clean)
    #expect(try await session.snapshot() == current)
  case .afterJournal:
    #expect(outcome == .notCommitted)
    #expect(try await session.snapshot() == current)
  case .afterReplacement, .afterReceipt:
    #expect(outcome == .committed)
    #expect(try await session.snapshot() == original)
    let restored = try JSONDecoder().decode(
      ProbeReceipt.self,
      from: Data(contentsOf: directory.appendingPathComponent("restore-receipt.json")))
    #expect(restored.beforeDigest == digest(current))
    #expect(restored.afterDigest == digest(original))
    #expect(restored.transactionID != applied.transactionID)
  }
  #expect(try Data(contentsOf: directory.appendingPathComponent("original.bin")) == original)
  #expect(try Data(contentsOf: directory.appendingPathComponent("receipt.json")) == applyReceipt)
  // Retry an uncommitted Restore, or verify the committed Restore is now a no-op.
  try await session.restoreOriginal(expectedDigest: digest(try await session.snapshot()))
  #expect(try await session.snapshot() == original)
  #expect(try await session.recover() == .clean)
  try await session.close()
}

@Test func restoreRecoveryPreservesExternalChanges() async throws {
  let session = try SandboxSession()
  let applied = try await session.apply(
    ProbeRequest(expectedDigest: digest(try await session.snapshot()), operation: .installExample))
  await #expect(throws: ProbeError.injectedFailure) {
    try await session.restoreOriginal(
      expectedDigest: applied.afterDigest, failure: .afterReplacement)
  }
  let target = await session.fixtureURL()
  let journal = target.deletingLastPathComponent().appendingPathComponent("journal.json")
  let journalBefore = try Data(contentsOf: journal)
  let external = Data("# external change after Restore\n".utf8)
  try external.write(to: target)
  #expect(try await session.recover() == .externalChange)
  #expect(try await session.snapshot() == external)
  #expect(try Data(contentsOf: journal) == journalBefore)
  await #expect(throws: ProbeError.recoveryRequired) {
    try await session.restoreOriginal(expectedDigest: digest(external))
  }
  try await session.close()
}

@Test func restoreRejectsStaleDigestAndNoOpDoesNotCreateTransaction() async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let applied = try await session.apply(
    ProbeRequest(expectedDigest: digest(original), operation: .installExample))
  await #expect(throws: ProbeError.staleRevision) {
    try await session.restoreOriginal(expectedDigest: digest(original))
  }
  #expect(digest(try await session.snapshot()) == applied.afterDigest)
  try await session.restoreOriginal(expectedDigest: applied.afterDigest)
  let directory = await session.fixtureURL().deletingLastPathComponent()
  let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  let bytes = try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
  try await session.restoreOriginal(expectedDigest: digest(original), failure: .beforeBackup)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
  #expect(try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) } == bytes)
  try await session.close()
}

@Test func restoreRecoveryRejectsCorruptedBeforeBackup() async throws {
  let session = try SandboxSession()
  let applied = try await session.apply(
    ProbeRequest(expectedDigest: digest(try await session.snapshot()), operation: .installExample))
  await #expect(throws: ProbeError.injectedFailure) {
    try await session.restoreOriginal(
      expectedDigest: applied.afterDigest, failure: .afterReplacement)
  }
  let target = await session.fixtureURL()
  let current = try await session.snapshot()
  let directory = target.deletingLastPathComponent()
  let journal = directory.appendingPathComponent("journal.json")
  let journalBefore = try Data(contentsOf: journal)
  try Data("# corrupted before-Restore backup\n".utf8)
    .write(to: directory.appendingPathComponent("restore-before.bin"))
  await #expect(throws: ProbeError.recoveryRequired) { try await session.recover() }
  #expect(try await session.snapshot() == current)
  #expect(try Data(contentsOf: journal) == journalBefore)
  try await session.close()
}

@Test(arguments: ["danglingSymlink", "symlink", "hardlink", "directory", "fifo"])
func unresolvedJournalEntryBlocksEveryOperation(kind: String) async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let applied = try await session.apply(
    ProbeRequest(expectedDigest: digest(original), operation: .installExample))
  let current = try await session.snapshot()
  let directory = await session.fixtureURL().deletingLastPathComponent()
  let journal = directory.appendingPathComponent("journal.json")
  try installUnsafeArtifact(at: journal, kind: kind)
  let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  let backup = try Data(contentsOf: directory.appendingPathComponent("original.bin"))
  let receipt = try Data(contentsOf: directory.appendingPathComponent("receipt.json"))
  let request = ProbeRequest(expectedDigest: applied.afterDigest, operation: .removeExample)
  await #expect(throws: ProbeError.recoveryRequired) { try await session.apply(request) }
  await #expect(throws: ProbeError.recoveryRequired) {
    try await session.restoreOriginal(expectedDigest: applied.afterDigest)
  }
  await #expect(throws: ProbeError.unsafeFile) { try await session.recover() }
  #expect(try await session.snapshot() == current)
  #expect(try Data(contentsOf: directory.appendingPathComponent("original.bin")) == backup)
  #expect(try Data(contentsOf: directory.appendingPathComponent("receipt.json")) == receipt)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
  try checkUnsafeArtifact(at: journal, kind: kind)
  try await session.close()
}

@Test(
  arguments: ["original.bin", "receipt.json", "restore-before.bin", "restore-receipt.json"],
  ["danglingSymlink", "symlink", "hardlink", "directory", "fifo"])
func unsafeCommitArtifactsAreRejectedBeforeAnyWrite(name: String, kind: String) async throws {
  let session = try SandboxSession()
  _ = try await session.apply(
    ProbeRequest(expectedDigest: digest(try await session.snapshot()), operation: .installExample))
  let current = try await session.snapshot()
  let directory = await session.fixtureURL().deletingLastPathComponent()
  let artifact = directory.appendingPathComponent(name)
  if FileManager.default.fileExists(atPath: artifact.path) {
    try FileManager.default.removeItem(at: artifact)
  }
  try installUnsafeArtifact(at: artifact, kind: kind)
  let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  let preservedNames = names.filter { $0 != name && $0 != "foreign.fixture" }
  let preservedBytes = try preservedNames.map {
    try Data(contentsOf: directory.appendingPathComponent($0))
  }
  if name.hasPrefix("restore-") {
    await #expect(throws: ProbeError.unsafeFile) {
      try await session.restoreOriginal(expectedDigest: digest(current))
    }
  } else {
    await #expect(throws: ProbeError.unsafeFile) {
      try await session.apply(
        ProbeRequest(expectedDigest: digest(current), operation: .removeExample))
    }
  }
  #expect(try await session.snapshot() == current)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
  #expect(
    try preservedNames.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
      == preservedBytes)
  #expect(try await session.recover() == .clean)
  try checkUnsafeArtifact(at: artifact, kind: kind)
  try await session.close()
}

@Test(
  arguments: [
    "badBefore", "badAfter", "equalDigests", "unchanged", "truncated", "missingDigest",
    "unknownField", "duplicateField", "escapedDuplicate", "trailingData", "nestedValue",
    "duplicateKind", "unknownJournalField", "duplicateReceipt",
  ],
  [false, true])
func invalidJournalPreservesTransaction(mutation: String, restoring: Bool) async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let request = ProbeRequest(expectedDigest: digest(original), operation: .installExample)
  if restoring {
    let applied = try await session.apply(request)
    await #expect(throws: ProbeError.injectedFailure) {
      try await session.restoreOriginal(expectedDigest: applied.afterDigest, failure: .afterJournal)
    }
  } else {
    await #expect(throws: ProbeError.injectedFailure) {
      try await session.apply(request, failure: .afterJournal)
    }
  }
  let directory = await session.fixtureURL().deletingLastPathComponent()
  let journal = directory.appendingPathComponent("journal.json")
  try corruptTransaction(at: journal, mutation: mutation, journal: true)
  let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  let before = try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
  await #expect(throws: ProbeError.recoveryRequired) { try await session.recover() }
  let current = try await session.snapshot()
  await #expect(throws: ProbeError.recoveryRequired) {
    try await session.apply(
      ProbeRequest(expectedDigest: digest(current), operation: .removeExample))
  }
  await #expect(throws: ProbeError.recoveryRequired) {
    try await session.restoreOriginal(expectedDigest: digest(current))
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
  #expect(try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) } == before)
  try await session.close()
}

@Test(arguments: [
  "badBefore", "badAfter", "equalDigests", "unchanged", "truncated", "missingDigest",
  "unknownField", "duplicateField", "escapedDuplicate", "trailingData", "nestedValue",
])
func invalidApplyReceiptBlocksRestoreWithoutWrites(mutation: String) async throws {
  let session = try SandboxSession()
  let applied = try await session.apply(
    ProbeRequest(expectedDigest: digest(try await session.snapshot()), operation: .installExample))
  let directory = await session.fixtureURL().deletingLastPathComponent()
  try corruptTransaction(
    at: directory.appendingPathComponent("receipt.json"), mutation: mutation, journal: false)
  let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  let before = try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
  await #expect(throws: ProbeError.recoveryRequired) {
    try await session.restoreOriginal(expectedDigest: applied.afterDigest)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
  #expect(try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) } == before)
  try await session.close()
}

private func corruptTransaction(at url: URL, mutation: String, journal: Bool) throws {
  let encoded = String(decoding: try Data(contentsOf: url), as: UTF8.self)
  let injection: String?
  switch mutation {
  case "unknownField": injection = #""unexpected":null,"#
  case "duplicateField": injection = #""unchanged":false,"#
  case "escapedDuplicate": injection = #""\u0075nchanged":false,"#
  case "nestedValue": injection = #""unchanged":{"unchanged":false},"#
  default: injection = nil
  }
  if let injection {
    let modified: String
    if journal {
      // Inject into the nested receipt, independently of JSONEncoder's field order.
      let range = try #require(
        encoded.range(of: "{", range: encoded.index(after: encoded.startIndex)..<encoded.endIndex))
      modified = String(encoded[..<range.upperBound]) + injection + encoded[range.upperBound...]
    } else {
      modified = "{" + injection + encoded.dropFirst()
    }
    try Data(modified.utf8).write(to: url)
    return
  }
  let extra: String?
  switch mutation {
  case "duplicateKind": extra = #""kind":"apply","#
  case "unknownJournalField": extra = #""unexpected":null,"#
  case "duplicateReceipt": extra = #""receipt":{},"#
  default: extra = nil
  }
  if let extra {
    try Data(("{" + extra + encoded.dropFirst()).utf8).write(to: url)
    return
  }
  if mutation == "trailingData" {
    try Data((encoded + "{}").utf8).write(to: url)
    return
  }
  if mutation == "truncated" {
    try Data("{".utf8).write(to: url)
    return
  }
  var object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  var record = try #require(journal ? object["receipt"] as? [String: Any] : object)
  switch mutation {
  case "badBefore": record["beforeDigest"] = "bad"
  case "badAfter": record["afterDigest"] = String(repeating: "G", count: 64)
  case "equalDigests": record["afterDigest"] = record["beforeDigest"]
  case "unchanged": record["unchanged"] = true
  case "missingDigest": record.removeValue(forKey: "afterDigest")
  default: Issue.record("Unexpected corruption kind")
  }
  if journal { object["receipt"] = record } else { object = record }
  try JSONSerialization.data(withJSONObject: object).write(to: url)
}

private func installUnsafeArtifact(at url: URL, kind: String) throws {
  let foreign = url.deletingLastPathComponent().appendingPathComponent("foreign.fixture")
  switch kind {
  case "danglingSymlink":
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: foreign)
  case "symlink", "hardlink":
    try Data("# foreign artifact\n".utf8).write(to: foreign, options: .withoutOverwriting)
    if kind == "hardlink" {
      try FileManager.default.linkItem(at: foreign, to: url)
    } else {
      try FileManager.default.createSymbolicLink(at: url, withDestinationURL: foreign)
    }
  case "directory":
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  case "fifo":
    let result = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return mkfifo(path, 0o600)
    }
    try #require(result == 0)
  default:
    Issue.record("Unexpected artifact kind")
  }
}

private func checkUnsafeArtifact(at url: URL, kind: String) throws {
  let foreign = url.deletingLastPathComponent().appendingPathComponent("foreign.fixture")
  var info = stat()
  let result = url.withUnsafeFileSystemRepresentation { path in
    guard let path else { return Int32(-1) }
    return lstat(path, &info)
  }
  try #require(result == 0)
  switch kind {
  case "danglingSymlink", "symlink":
    #expect(info.st_mode & S_IFMT == S_IFLNK)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == foreign.path)
  case "hardlink":
    #expect(info.st_mode & S_IFMT == S_IFREG)
    #expect(info.st_nlink == 2)
    #expect(try Data(contentsOf: url) == Data("# foreign artifact\n".utf8))
  case "directory":
    #expect(info.st_mode & S_IFMT == S_IFDIR)
    #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
  case "fifo":
    #expect(info.st_mode & S_IFMT == S_IFIFO)
  default:
    Issue.record("Unexpected artifact kind")
  }
  if kind == "danglingSymlink" {
    #expect(!FileManager.default.fileExists(atPath: foreign.path))
  } else if kind == "symlink" || kind == "hardlink" {
    #expect(try Data(contentsOf: foreign) == Data("# foreign artifact\n".utf8))
  }
}

@Test(arguments: [false, true])
func persistedRecordsAcceptEscapedKeysAndWhitespace(journal: Bool) async throws {
  let session = try SandboxSession()
  let request = ProbeRequest(
    expectedDigest: digest(try await session.snapshot()), operation: .installExample)
  if journal {
    await #expect(throws: ProbeError.injectedFailure) {
      try await session.apply(request, failure: .afterReplacement)
    }
  } else {
    _ = try await session.apply(request)
  }
  let directory = await session.fixtureURL().deletingLastPathComponent()
  let record = directory.appendingPathComponent(journal ? "journal.json" : "receipt.json")
  let encoded = String(decoding: try Data(contentsOf: record), as: UTF8.self)
  let escaped = encoded.replacingOccurrences(of: "beforeDigest", with: #"\u0062eforeDigest"#)
    .replacingOccurrences(of: ":", with: " \n:\t")
  try Data(("\r\n" + escaped + "\t").utf8).write(to: record)
  if journal { #expect(try await session.recover() == .committed) }
  try await session.restoreOriginal(expectedDigest: digest(try await session.snapshot()))
  #expect(digest(try await session.snapshot()) == request.expectedDigest)
  try await session.close()
}

@Test(arguments: [false, true])
func rejectsEveryTruncatedPersistedRecord(journal: Bool) async throws {
  let session = try SandboxSession()
  await #expect(throws: ProbeError.injectedFailure) {
    try await session.apply(
      ProbeRequest(
        expectedDigest: digest(try await session.snapshot()), operation: .installExample),
      failure: .afterReceipt)
  }
  let directory = await session.fixtureURL().deletingLastPathComponent()
  let encoded = try Data(
    contentsOf: directory.appendingPathComponent(journal ? "journal.json" : "receipt.json"))
  for length in 0..<encoded.count {
    #expect(throws: ProbeError.recoveryRequired) {
      try TransactionJSON.validate(Data(encoded.prefix(length)), journal: journal)
    }
  }
  try await session.close()
}

@Test(arguments: [0o620, 0o602, 0o666])
func writableByOthersFixtureBlocksApply(mode: Int) async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let fixture = await session.fixtureURL()
  try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: fixture.path)
  await #expect(throws: ProbeError.unsafeFile) { try await session.snapshot() }
  await #expect(throws: ProbeError.unsafeFile) {
    try await session.apply(
      ProbeRequest(expectedDigest: digest(original), operation: .installExample))
  }
  #expect(try Data(contentsOf: fixture) == original)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: fixture.deletingLastPathComponent().path)
      == ["hosts.fixture"])
  try await session.close()
}

@Test(
  arguments: ["original.bin", "receipt.json", "restore-before.bin", "restore-receipt.json"],
  [0o620, 0o602])
func writableByOthersArtifactsBlockCommit(name: String, mode: Int) async throws {
  let session = try SandboxSession()
  _ = try await session.apply(
    ProbeRequest(expectedDigest: digest(try await session.snapshot()), operation: .installExample))
  let directory = await session.fixtureURL().deletingLastPathComponent()
  let artifact = directory.appendingPathComponent(name)
  if name.hasPrefix("restore-") { try Data("existing artifact".utf8).write(to: artifact) }
  try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: artifact.path)
  let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  let bytes = try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
  let currentDigest = digest(try await session.snapshot())
  if name.hasPrefix("restore-") {
    await #expect(throws: ProbeError.unsafeFile) {
      try await session.restoreOriginal(expectedDigest: currentDigest)
    }
  } else {
    await #expect(throws: ProbeError.unsafeFile) {
      try await session.apply(
        ProbeRequest(expectedDigest: currentDigest, operation: .removeExample))
    }
    // Restore must also reject unsafe backup/receipt input before any writes.
    await #expect(throws: ProbeError.unsafeFile) {
      try await session.restoreOriginal(expectedDigest: currentDigest)
    }
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
  #expect(try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) } == bytes)
  let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
  try await session.close()
}

@Test(arguments: ["journal.json", "original.bin"], [0o620, 0o602])
func writableByOthersRecoveryInputPreservesJournal(name: String, mode: Int) async throws {
  let session = try SandboxSession()
  await #expect(throws: ProbeError.injectedFailure) {
    try await session.apply(
      ProbeRequest(
        expectedDigest: digest(try await session.snapshot()), operation: .installExample),
      failure: .afterReplacement)
  }
  let directory = await session.fixtureURL().deletingLastPathComponent()
  try FileManager.default.setAttributes(
    [.posixPermissions: mode], ofItemAtPath: directory.appendingPathComponent(name).path)
  let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  let bytes = try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
  await #expect(throws: ProbeError.unsafeFile) { try await session.recover() }
  await #expect(throws: ProbeError.recoveryRequired) {
    try await session.restoreOriginal(expectedDigest: digest(try await session.snapshot()))
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
  #expect(try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) } == bytes)
  try await session.close()
}

@Test(arguments: [0o400, 0o600, 0o644])
func fixtureWithoutOtherWritePermissionsRemainsReadable(mode: Int) async throws {
  let session = try SandboxSession()
  let original = try await session.snapshot()
  let fixture = await session.fixtureURL()
  try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: fixture.path)
  #expect(try await session.snapshot() == original)
  try await session.close()
}
