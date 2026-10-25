import Foundation
import HostsCore
import Testing

@testable import HostsServices

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
