import Foundation
import HostsCore
import Testing

@testable import HostsServices

@Test func diagnosticNavigationSelectsExactUnicodeLineAndRejectsChangedSource() throws {
  let source = "# 🌍 Grüße\r\ninvalid 😀 address\r192.0.2.1\n"
  let document = HostsDocument.parse(Data(source.utf8), context: .profile)
  for diagnostic in document.diagnostics {
    let location = try #require(
      ProfileDiagnosticLocation(document: document, line: diagnostic.line))
    let range = try #require(location.range(in: source))
    let expected = diagnostic.line == 2 ? "invalid 😀 address" : "192.0.2.1"
    #expect((source as NSString).substring(with: range) == expected)
    #expect(location.range(in: "# inserted\n" + source) == nil)
    #expect(location.range(in: source.replacingOccurrences(of: "\r\n", with: "\n")) == nil)
  }
  #expect(document.diagnostics.count == 2)
  #expect(ProfileDiagnosticLocation(document: document, line: nil) == nil)
  #expect(ProfileDiagnosticLocation(document: document, line: 0) == nil)
  #expect(ProfileDiagnosticLocation(document: document, line: 99) == nil)
  let unsupported = HostsDocument.parse(Data([0xff]), context: .profile)
  #expect(ProfileDiagnosticLocation(document: unsupported, line: 1) == nil)
}

@Test func editorPresentationUsesParserAndPreservesUnicodeOffsets() {
  let source = "# 🌍 Grüße\r\n\t2001:db8::1\tExample.test alias.test # ü\r192.0.2.1 other.test\n"
  let presentation = ProfileEditorPresentation.make(source: source)
  let text = source as NSString
  #expect(presentation.lineStarts == [0, 12, 53, 74])
  let fragments = presentation.spans.map { text.substring(with: $0.range) }
  #expect(
    fragments == [
      "# 🌍 Grüße", "2001:db8::1", "Example.test", "alias.test", "# ü", "192.0.2.1", "other.test",
    ])
  #expect(
    presentation.spans.map(\.style) == [
      .comment, .address, .hostname, .hostname, .comment, .address, .hostname,
    ])
  for span in presentation.spans { #expect(NSMaxRange(span.range) <= text.length) }
}

@Test func editorPresentationDistinguishesDisabledInvalidAndOrdinaryComments() {
  let source =
    "# machosts-disabled: 192.0.2.1 disabled.test\n# 192.0.2.2 comment.test\n999.0.0.1 bad.test\n192.0.2.3 https://bad.test\n\(HostsSyntax.begin)\n\n"
  let presentation = ProfileEditorPresentation.make(source: source)
  #expect(presentation.spans.map(\.style) == [.disabled, .comment, .invalid, .invalid, .invalid])
  #expect(presentation.lineStarts.count == 7)
  let parsed = HostsDocument.parse(Data(source.utf8), context: .profile)
  #expect(parsed.diagnostics.map(\.line) == [3, 4, 5])
}

@Test(arguments: ["", "\n", "\r", "\r\n", "\n\r\n\r", "x", "x\r\ny", "# 😀\n"])
func editorLineStartsFollowExactTerminators(source: String) {
  let presentation = ProfileEditorPresentation.make(source: source)
  let text = source as NSString
  var expected = [0]
  var index = 0
  while index < text.length {
    let unit = text.character(at: index)
    index += 1
    if unit == 13 && index < text.length && text.character(at: index) == 10 { index += 1 }
    if unit == 13 || unit == 10 { expected.append(index) }
  }
  #expect(presentation.lineStarts == expected)
}

@Test func editorPresentationDoesNotTokenizeUnicodeCommentAsHosts() {
  let source = "192.0.2.1 host.test# 😀 2001:db8::1 fake.test"
  let presentation = ProfileEditorPresentation.make(source: source)
  let text = source as NSString
  #expect(
    presentation.spans.map { text.substring(with: $0.range) } == [
      "192.0.2.1", "host.test", "# 😀 2001:db8::1 fake.test",
    ])
  #expect(presentation.lineStarts == [0])
}

@Test func editorStylerUsesNewSnapshotWithoutRetainingOldPositions() async {
  let styler = ProfileEditorStyler()
  let first = await styler.presentation(for: "# 😀\r\n192.0.2.1 old.test\r\n")
  let second = await styler.presentation(for: "invalid")
  #expect(first.lineStarts.count == 3)
  #expect(second.lineStarts == [0])
  #expect(second.spans.count == 1)
  #expect(second.spans.first?.range == NSRange(location: 0, length: 7))
  #expect(second.spans.first?.style == .invalid)
}

@Test func editorRulerIncludesLinesBeyondParserLimitAndUnsupportedBOM() {
  let large = String(repeating: "\n", count: HostsLimits.systemLines + 2)
  let presentation = ProfileEditorPresentation.make(source: large)
  #expect(presentation.lineStarts.count == HostsLimits.systemLines + 3)
  #expect(presentation.lineStarts.last == large.utf16.count)
  #expect(presentation.spans.isEmpty)
  let bom = ProfileEditorPresentation.make(source: "\u{feff}# comment\r\ninvalid\n")
  #expect(bom.lineStarts == [0, 12, 20])
  #expect(bom.spans.isEmpty)
}

@Test func systemPresentationHighlightsOnlyValidatedManagedBlockWithUTF16Offsets() throws {
  let prefix = "# 🌍 foreign\r\n192.0.2.2 foreign.example\r\n"
  let block = HostsSyntax.begin + "\r\n192.0.2.1 managed.example\r\n" + HostsSyntax.end + "\r\n"
  let source = prefix + block + "# suffix\r\n"
  let presentation = ProfileEditorPresentation.make(source: source, system: true)
  let managed = try #require(presentation.spans.first { $0.style == .managed })
  #expect(managed.range == NSRange(location: prefix.utf16.count, length: block.utf16.count))
  #expect(presentation.spans.filter { $0.style == .managed }.count == 1)
  #expect(!presentation.spans.contains { $0.style == .invalid })
  #expect(!ProfileEditorPresentation.make(source: source).spans.contains { $0.style == .managed })
  for malformed in [HostsSyntax.begin, HostsSyntax.end + "\n" + HostsSyntax.begin, block + block] {
    #expect(
      !ProfileEditorPresentation.make(source: malformed, system: true).spans.contains {
        $0.style == .managed
      })
  }
  // System display must use the 4 MiB system budget, not the 1 MiB profile budget.
  let largePrefix = "#" + String(repeating: "a", count: HostsLimits.profileBytes) + "\n"
  let large = ProfileEditorPresentation.make(source: largePrefix + block, system: true)
  #expect(large.spans.first { $0.style == .managed }?.range.location == largePrefix.utf16.count)
  // A partial parse cannot prove that no second marker exists later in the file.
  let limited = block + String(repeating: "\n", count: HostsLimits.systemLines) + block
  #expect(
    !ProfileEditorPresentation.make(source: limited, system: true).spans.contains {
      $0.style == .managed
    })
}
