import AppKit
import HostsCore
import HostsServices
import Observation
import SwiftUI

@MainActor @Observable final class ProbeDraft {
  var source = "# 🌍 Grüße\r\n192.0.2.1 test.example # comment\r\n"
  var jump: ProfileEditorJump?
  var findRequest: ProfileEditorFindRequest?
}
struct ProbeView: View {
  let model: ProbeDraft
  var body: some View {
    NativeProfileEditor(
      source: model.source, isEditable: true, jump: model.jump, findRequest: model.findRequest,
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
    // Diagnostic navigation uses UTF-16 and must preserve redo and source bytes.
    guard
      let location = ProfileDiagnosticLocation(
        document: HostsDocument.parse(Data(original.utf8), context: .profile), line: 2)
    else { fatalError("Diagnostic line location missing") }
    draft.jump = ProfileEditorJump(
      id: UUID(), profileID: UUID(), digest: location.digest, range: location.range)
    try await Task.sleep(for: .milliseconds(200))
    precondition(text.selectedRange() == location.range)
    precondition(window.firstResponder === text && draft.source == original)
    precondition(text.undoManager?.canRedo == true)
    text.setSelectedRange(NSRange(location: 0, length: 0))
    draft.jump = ProfileEditorJump(
      id: UUID(), profileID: UUID(), digest: ContentDigest(Data("stale".utf8)),
      range: location.range)
    try await Task.sleep(for: .milliseconds(200))
    precondition(text.selectedRange() == NSRange(location: 0, length: 0))
    text.undoManager?.redo()
    try await Task.sleep(for: .milliseconds(450))
    precondition(draft.source == original + "invalid")
    // Menu requests must focus the selected editor, preserve text/undo, and use AppKit's find bar.
    guard let scroll = text.enclosingScrollView else { fatalError("Editor scroll view missing") }
    draft.findRequest = ProfileEditorFindRequest(profileID: UUID(), replace: false)
    try await Task.sleep(for: .milliseconds(250))
    precondition(scroll.isFindBarVisible)
    precondition(draft.source == original + "invalid" && text.undoManager?.canUndo == true)
    let hideFind = NSMenuItem()
    hideFind.tag = NSTextFinder.Action.hideFindInterface.rawValue
    text.performTextFinderAction(hideFind)
    precondition(!scroll.isFindBarVisible)
    // Unrelated updates must not reopen a dismissed find bar.
    draft.jump = nil
    try await Task.sleep(for: .milliseconds(150))
    precondition(!scroll.isFindBarVisible)
    draft.findRequest = ProfileEditorFindRequest(profileID: UUID(), replace: true)
    try await Task.sleep(for: .milliseconds(250))
    precondition(scroll.isFindBarVisible && text.string == draft.source)
    text.performTextFinderAction(hideFind)
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
    // Two editors in one window must never share undo with each other or the window.
    let otherDraft = ProbeDraft()
    let pair = NSHostingView(
      rootView: VStack {
        ProbeView(model: draft)
        ProbeView(model: otherDraft)
      })
    window.contentView = pair
    pair.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(450))
    func editors(in view: NSView) -> [NSTextView] {
      if let text = view as? NSTextView { return [text] }
      return view.subviews.flatMap { editors(in: $0) }
    }
    let pairEditors = editors(in: pair)
    precondition(pairEditors.count == 2)
    let first = pairEditors[0]
    let second = pairEditors[1]
    precondition(first.undoManager !== second.undoManager)
    precondition(first.undoManager !== window.undoManager)
    let firstOriginal = draft.source
    let secondOriginal = otherDraft.source
    for text in pairEditors {
      window.makeFirstResponder(text)
      text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
      text.insertText("# local edit\n", replacementRange: text.selectedRange())
      text.breakUndoCoalescing()
    }
    try await Task.sleep(for: .milliseconds(200))
    precondition(draft.source == firstOriginal + "# local edit\n")
    precondition(otherDraft.source == secondOriginal + "# local edit\n")
    // Replacing one draft invalidates its offsets without destroying another editor's history.
    draft.source = "# external replacement\n"
    try await Task.sleep(for: .milliseconds(200))
    precondition(first.undoManager?.canUndo == false)
    precondition(second.undoManager?.canUndo == true)
    second.undoManager?.undo()
    try await Task.sleep(for: .milliseconds(200))
    precondition(otherDraft.source == secondOriginal)
    precondition(draft.source == "# external replacement\n")
    // A second window on the same draft receives updates, rejects obsolete undo,
    // and cannot erase the originating editor's valid redo history.
    let mirrorHost = NSHostingView(rootView: ProbeView(model: otherDraft))
    let mirrorWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    mirrorWindow.isReleasedWhenClosed = false
    mirrorWindow.contentView = mirrorHost
    mirrorWindow.orderFront(nil)
    defer { mirrorWindow.close() }
    mirrorHost.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    guard let mirror = editor(in: mirrorHost) else { fatalError("Mirror editor missing") }
    mirrorWindow.makeFirstResponder(mirror)
    mirror.setSelectedRange(NSRange(location: 0, length: 0))
    mirror.insertText("# mirror\n", replacementRange: mirror.selectedRange())
    mirror.breakUndoCoalescing()
    try await Task.sleep(for: .milliseconds(200))
    precondition(second.string == "# mirror\n" + secondOriginal)
    precondition(second.undoManager?.canRedo == false)
    mirror.undoManager?.undo()
    try await Task.sleep(for: .milliseconds(200))
    precondition(second.string == secondOriginal && mirror.string == secondOriginal)
    precondition(mirror.undoManager?.canRedo == true)
    precondition(second.undoManager?.canUndo == false)
    print(
      "PASS: isolated editor undo managers, shared-draft synchronization across windows, stale undo rejection"
    )
    // Exercise the production system renderer with in-memory bytes only.
    let systemPrefix = "# 🌍 foreign\r\n"
    let systemSource =
      systemPrefix + HostsSyntax.begin + "\r\n192.0.2.1 managed.example\r\n"
      + HostsSyntax.end + "\r\n"
    let systemHost = NSHostingView(
      rootView:
        NativeProfileEditor(source: systemSource, isSystem: true, isEditable: false, jump: nil) {
          $0
        })
    window.contentView = systemHost
    systemHost.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(700))
    guard let systemText = editor(in: systemHost), let systemLayout = systemText.layoutManager
    else {
      fatalError("System contents editor missing")
    }
    precondition(!systemText.isEditable && systemText.isSelectable && systemText.usesFindBar)
    precondition(systemText.string == systemSource)
    precondition(systemText.accessibilityIdentifier() == "systemSource")
    precondition(
      systemLayout.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)[.backgroundColor]
        == nil)
    precondition(
      systemLayout.temporaryAttributes(
        atCharacterIndex: systemPrefix.utf16.count, effectiveRange: nil)[.backgroundColor] != nil)
    systemText.setSelectedRange(NSRange(location: 0, length: systemPrefix.utf16.count))
    precondition(systemText.selectedRange().length == systemPrefix.utf16.count)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      window.appearance = NSAppearance(named: appearance)
      try await Task.sleep(for: .milliseconds(100))
      guard let bitmap = systemText.bitmapImageRepForCachingDisplay(in: systemText.bounds) else {
        fatalError("Cannot render system contents")
      }
      systemText.cacheDisplay(in: systemText.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode system contents")
      }
      try png.write(to: URL(fileURLWithPath: "/tmp/machosts-system-contents-\(name).png"))
    }
    print(
      "PASS: read-only selectable system text, exact CRLF/Unicode, temporary managed block highlighting"
    )
    print(
      "PASS: native bridge, temporary colors, exact CRLF/Unicode text, line count, selection, undo/redo, external replacement, large-profile scrolling, latest-snapshot styling and ruler drawing"
    )
  }
}
