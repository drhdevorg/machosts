import AppKit
import HostsServices
import Observation
import SwiftUI

@MainActor @Observable final class ProbeDraft {
  var source = "# 🌍 Grüße\r\n192.0.2.1 test.example # comment\r\n"
}
struct ProbeView: View {
  let model: ProbeDraft
  var body: some View {
    NativeProfileEditor(
      source: model.source, isEditable: true, jump: nil,
      onChange: {
        model.source = $0
        return $0
      })
  }
}
@main struct EditorProbe {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let draft = ProbeDraft()
    let original = draft.source
    let host = NSHostingView(rootView: ProbeView(model: draft))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(700))
    func editor(in view: NSView) -> NSTextView? {
      if let text = view as? NSTextView { return text }
      return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    guard let text = editor(in: host), let layout = text.layoutManager,
      let ruler = text.enclosingScrollView?.verticalRulerView
    else { fatalError("Native editor or ruler missing") }
    precondition(text.string == original && draft.source == original)
    precondition(!text.isRichText && text.allowsUndo && text.usesFindBar)
    precondition(ruler.accessibilityValue() as? String == "3")
    let attributes = layout.temporaryAttributes(atCharacterIndex: 12, effectiveRange: nil)
    precondition((attributes[.foregroundColor] as? NSColor) == .systemBlue)
    precondition(
      text.textStorage?.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? NSColor
        != .systemBlue)
    window.makeFirstResponder(text)
    text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
    text.insertText("invalid", replacementRange: text.selectedRange())
    text.breakUndoCoalescing()
    try await Task.sleep(for: .milliseconds(450))
    precondition(draft.source == original + "invalid")
    let invalid = layout.temporaryAttributes(
      atCharacterIndex: (original as NSString).length,
      effectiveRange: nil)
    precondition((invalid[.foregroundColor] as? NSColor) == .systemRed)
    precondition(text.selectedRange().location == (draft.source as NSString).length)
    precondition(text.undoManager?.canUndo == true)
    text.undoManager?.undo()
    try await Task.sleep(for: .milliseconds(450))
    precondition(draft.source == original && text.string == original)
    precondition(text.undoManager?.canRedo == true)
    text.undoManager?.redo()
    try await Task.sleep(for: .milliseconds(450))
    precondition(draft.source == original + "invalid")
    draft.source = "# replacement\n"
    try await Task.sleep(for: .milliseconds(450))
    precondition(text.string == draft.source && text.undoManager?.canUndo == false)
    precondition(ruler.accessibilityValue() as? String == "2")
    precondition(
      layout.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)[.underlineStyle] == nil)
    // Exercise viewport drawing and the final empty line without Accessibility automation.
    draft.source = String(repeating: "192.0.2.1 scroll.example\n", count: 10000)
    try await Task.sleep(for: .milliseconds(700))
    precondition(ruler.accessibilityValue() as? String == "10001")
    text.scrollRangeToVisible(NSRange(location: (draft.source as NSString).length, length: 0))
    ruler.displayIfNeeded()
    // Obsolete presentations must not recolor a newer draft with older offsets.
    draft.source = "192.0.2.1 old.example\n"
    try await Task.sleep(for: .milliseconds(30))
    draft.source = "# latest\n"
    try await Task.sleep(for: .milliseconds(450))
    precondition(text.string == "# latest\n")
    precondition(ruler.accessibilityValue() as? String == "2")
    precondition(
      (layout.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)[.foregroundColor]
        as? NSColor) == .secondaryLabelColor)
    draft.source =
      "# 🌍 Unicode comment\r\n192.0.2.1 stage.example # staging\r\n# machosts-disabled: ::1 local.test\ninvalid address\n"
    try await Task.sleep(for: .milliseconds(450))
    text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      window.appearance = NSAppearance(named: appearance)
      try await Task.sleep(for: .milliseconds(100))
      // Render native surfaces directly: NSHostingView's bitmap cache omits the
      // layer-backed text view on this SDK, even though the text itself renders.
      for (surface, view) in [("text", text as NSView), ("ruler", ruler as NSView)] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
          fatalError("Cannot render editor surface")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
          fatalError("Cannot encode editor rendering")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/machosts-editor-\(surface)-\(name).png"))
      }
    }
    print(
      "PASS: native bridge, temporary colors, exact CRLF/Unicode text, line count, selection, undo/redo, external replacement, large-profile scrolling, latest-snapshot styling and ruler drawing"
    )
  }
}
