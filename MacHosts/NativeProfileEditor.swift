import AppKit
import HostsCore
import HostsServices
import SwiftUI

struct ProfileEditorJump: Equatable {
  let id: UUID
  let profileID: UUID
  let digest: ContentDigest
  let range: NSRange?
}

struct ProfileEditorFindRequest: Equatable {
  let id = UUID()
  let profileID: UUID
  let replace: Bool
}

/// NSTextView keeps native selection, undo and find/replace. A view identity belongs to
/// one profile so its undo stack can never modify a different profile after selection.
struct NativeProfileEditor: NSViewRepresentable {
  let source: String
  var isSystem = false
  let isEditable: Bool
  let jump: ProfileEditorJump?
  var findRequest: ProfileEditorFindRequest? = nil
  let onChange: (String) -> String

  func makeCoordinator() -> Coordinator { Coordinator(isSystem: isSystem, onChange: onChange) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.borderType = .bezelBorder
    let text = ProfileTextView(frame: .zero)
    text.isEditable = isEditable
    text.isRichText = false
    text.allowsUndo = true
    text.usesFindBar = true
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.isAutomaticTextReplacementEnabled = false
    text.isAutomaticSpellingCorrectionEnabled = false
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = false
    text.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    text.textContainerInset = NSSize(width: 8, height: 8)
    text.setAccessibilityIdentifier(isSystem ? "systemSource" : "profileSource")
    text.setAccessibilityLabel(
      isSystem ? String(localized: "System file contents") : String(localized: "Profile source"))
    text.textColor = .textColor
    text.insertionPointColor = .textColor
    text.string = source
    context.coordinator.current = source
    text.delegate = context.coordinator
    scroll.documentView = text
    scroll.verticalRulerView = ProfileLineRuler(textView: text, scrollView: scroll)
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
      name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    context.coordinator.schedulePresentation(for: text)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? ProfileTextView else { return }
    context.coordinator.onChange = onChange
    text.isEditable = isEditable
    context.coordinator.schedulePresentation(for: text, source: source)
    if context.coordinator.current != source {
      let selection = text.selectedRange()
      text.string = source
      context.coordinator.current = source
      let count = (source as NSString).length
      let location = min(selection.location, count)
      text.setSelectedRange(
        NSRange(location: location, length: min(selection.length, count - location)))
      // Programmatic line switches/rejected edits invalidate older text offsets.
      text.undoManager?.removeAllActions()
    }
    if let findRequest, context.coordinator.lastFind != findRequest.id {
      context.coordinator.lastFind = findRequest.id
      text.pendingFind =
        findRequest.replace && isEditable ? .showReplaceInterface : .showFindInterface
      text.showPendingFind()
    }

    if let jump, context.coordinator.lastJump != jump.id {
      context.coordinator.lastJump = jump.id
      // A stale result must never select offsets in a more recent draft.
      if jump.digest == ContentDigest(Data(source.utf8)), let range = jump.range,
        NSMaxRange(range) <= (source as NSString).length
      {
        text.breakUndoCoalescing()
        text.setSelectedRange(range)
        text.scrollRangeToVisible(range)
        if let window = text.window {
          window.makeFirstResponder(text)
        } else {
          text.focusOnAttach = true
        }
      }
    }
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.styling?.cancel()
    NotificationCenter.default.removeObserver(
      coordinator, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    (scroll.documentView as? NSTextView)?.delegate = nil
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    let isSystem: Bool
    private let styler = ProfileEditorStyler()
    private var requestedSource: String?
    var styling: Task<Void, Never>?

    func schedulePresentation(for text: NSTextView, source: String? = nil) {
      let source = source ?? current
      guard requestedSource != source else { return }
      requestedSource = source
      styling?.cancel()
      styling = Task { [weak self, weak text, styler, isSystem] in
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        let presentation = await styler.presentation(for: source, system: isSystem)
        guard !Task.isCancelled, let self, let text, current == source else { return }
        self.presentation = presentation.spans.filter { $0.style != .managed }
        managedSpans = presentation.spans.filter { $0.style == .managed }
        styled = IndexSet()
        styleVisibleText(text)
        (text.enclosingScrollView?.verticalRulerView as? ProfileLineRuler)?
          .update(lineStarts: presentation.lineStarts)
      }
    }
    private var presentation: [ProfileEditorPresentation.Span] = []
    private var managedSpans: [ProfileEditorPresentation.Span] = []
    private var styled = IndexSet()

    /// Colors only the visible text plus one screen above and below, and the rest as it
    /// scrolls into view. Restyling all 10,000 lines after every typing pause stalled
    /// the main thread. Ranges styled for an older presentation are restyled when the
    /// new one reaches them, because the styled set is reset per presentation.
    func styleVisibleText(_ text: NSTextView) {
      guard let layout = text.layoutManager, let container = text.textContainer else { return }
      let visible = text.visibleRect
      guard !visible.isEmpty else { return }
      let area = visible.insetBy(dx: 0, dy: -visible.height).offsetBy(
        dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
      let glyphs = layout.glyphRange(forBoundingRect: area, in: container)
      let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      let length = text.textStorage?.length ?? 0
      let lower = min(characters.location, length)
      let upper = min(NSMaxRange(characters), length)
      guard lower < upper else { return }
      let missing = IndexSet(integersIn: lower..<upper).subtracting(styled)
      for range in missing.rangeView {
        style(NSRange(location: range.lowerBound, length: range.count), in: layout)
      }
      styled.insert(integersIn: lower..<upper)
    }

    private func style(_ range: NSRange, in layout: NSLayoutManager) {
      layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
      layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
      layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
      for span in managedSpans {
        let part = NSIntersectionRange(span.range, range)
        if part.length > 0 {
          layout.addTemporaryAttribute(
            .backgroundColor, value: NSColor.systemBlue.withAlphaComponent(0.12),
            forCharacterRange: part)
        }
      }
      // Line spans are in source order; start at the first one that ends after the range.
      var lower = 0
      var upper = presentation.count
      while lower < upper {
        let mid = (lower + upper) / 2
        if NSMaxRange(presentation[mid].range) <= range.location {
          lower = mid + 1
        } else {
          upper = mid
        }
      }
      for span in presentation[lower...] {
        if span.range.location >= NSMaxRange(range) { break }
        let part = NSIntersectionRange(span.range, range)
        guard part.length > 0 else { continue }
        let color: NSColor
        switch span.style {
        case .address: color = .systemBlue
        case .hostname: color = .textColor
        case .comment, .disabled, .managed: color = .secondaryLabelColor
        case .invalid: color = .systemRed
        }
        layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: part)
        if span.style == .invalid {
          layout.addTemporaryAttribute(
            .underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: part)
        }
      }
    }

    private var visibleStylingQueued = false

    /// Bounds also change while AppKit tiles the scroll view (for example when the find
    /// bar opens). Styling forces glyph layout, so it runs once on the next main-queue
    /// turn instead of inside that pass; the one-screen margin covers ordinary scrolling.
    @objc func scrolled(_ notification: Notification) {
      guard !visibleStylingQueued, let clip = notification.object as? NSClipView,
        let text = clip.documentView as? NSTextView
      else { return }
      visibleStylingQueued = true
      DispatchQueue.main.async { [weak self, weak text] in
        guard let self else { return }
        visibleStylingQueued = false
        if let text { styleVisibleText(text) }
      }
    }

    /// A native copy of the text view's contents. `NSTextView.string` bridges to a
    /// Foundation-backed String, and comparing such a String with a large profile source
    /// falls back to slow Unicode comparison in every SwiftUI and model equality check.
    var current = ""
    var lastJump: UUID?
    var lastFind: UUID?
    var onChange: (String) -> String
    init(isSystem: Bool, onChange: @escaping (String) -> String) {
      self.isSystem = isSystem
      self.onChange = onChange
    }
    /// Copies the text storage into native UTF-8 in one Foundation transcoding pass,
    /// about 20 times faster than bridging and normalizing `NSTextView.string` for a
    /// 10,000-line profile. Unpaired UTF-16 surrogates fall back to the bridged copy.
    static func nativeCopy(of text: NSTextView) -> String {
      if let storage = text.textStorage {
        let contents = storage.mutableString
        let length = contents.length
        guard length > 0 else { return "" }
        var remaining = NSRange(location: 0, length: 0)
        let copy = String(unsafeUninitializedCapacity: length * 3) { buffer in
          var used = 0
          contents.getBytes(
            buffer.baseAddress, maxLength: buffer.count, usedLength: &used,
            encoding: String.Encoding.utf8.rawValue, options: [],
            range: NSRange(location: 0, length: length), remaining: &remaining)
          return used
        }
        if remaining.length == 0 { return copy }
      }
      var bridged = text.string
      bridged.makeContiguousUTF8()
      return bridged
    }

    func textDidChange(_ notification: Notification) {
      guard let text = notification.object as? NSTextView else { return }
      let edited = Self.nativeCopy(of: text)
      current = edited
      let accepted = onChange(edited)
      if edited != accepted {
        let location = min(text.selectedRange().location, (accepted as NSString).length)
        text.string = accepted
        current = accepted
        text.setSelectedRange(NSRange(location: location, length: 0))
        text.undoManager?.removeAllActions()
      }
      schedulePresentation(for: text)
    }
  }
}

/// A search can create a new profile editor before SwiftUI attaches it to a window.
private final class ProfileTextView: NSTextView {
  // A window's default undo manager can outlive a selected profile and includes
  // other controls. External draft updates must clear only this editor's history.
  private let editorUndoManager = UndoManager()
  override var undoManager: UndoManager? { editorUndoManager }

  var focusOnAttach = false
  var pendingFind: NSTextFinder.Action?

  func showPendingFind() {
    guard let window, let action = pendingFind else { return }
    pendingFind = nil
    window.makeFirstResponder(self)
    let sender = NSMenuItem()
    sender.tag = action.rawValue
    performTextFinderAction(sender)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    showPendingFind()
    if focusOnAttach, let window {
      focusOnAttach = false
      window.makeFirstResponder(self)
      scrollRangeToVisible(selectedRange())
    }
  }
}

/// Draw only visible logical lines; long unwrapped lines retain one number. Layout
/// positions come from NSTextView so scrolling, insets and font metrics stay aligned.
private final class ProfileLineRuler: NSRulerView {
  private var lineStarts = [0]
  private let numberFont = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.smallSystemFontSize,
    weight: .regular)

  init(textView: NSTextView, scrollView: NSScrollView) {
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 42
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityIdentifier("profileLineNumbers")
    setAccessibilityLabel(String(localized: "Line numbers"))
    setAccessibilityValue("1")
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(scrolled),
      name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func scrolled() { needsDisplay = true }

  func update(lineStarts: [Int]) {
    self.lineStarts = lineStarts
    let width = (String(lineStarts.count) as NSString).size(withAttributes: [.font: numberFont])
      .width
    ruleThickness = max(42, ceil(width) + 16)
    setAccessibilityValue(String(lineStarts.count))
    needsDisplay = true
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    rect.fill()
    guard let text = clientView as? NSTextView, let layout = text.layoutManager,
      let container = text.textContainer
    else { return }
    let visible = text.visibleRect.offsetBy(
      dx: -text.textContainerOrigin.x,
      dy: -text.textContainerOrigin.y)
    let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    // Binary search avoids walking all previous lines while scrolling a large profile.
    var lower = 0
    var upper = lineStarts.count
    while lower < upper {
      let mid = (lower + upper) / 2
      if lineStarts[mid] < characters.location { lower = mid + 1 } else { upper = mid }
    }
    var index = max(0, lower - 1)
    let count = text.textStorage?.length ?? 0
    while index < lineStarts.count {
      let start = lineStarts[index]
      guard start <= count else { break }  // An edit may precede the asynchronous presentation.
      if start > NSMaxRange(characters) { break }
      let fragment: NSRect
      if start == count {
        fragment = layout.extraLineFragmentRect
      } else {
        let glyph = layout.glyphIndexForCharacter(at: start)
        fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      }
      if fragment.height > 0 {
        let point = convert(
          NSPoint(x: 0, y: fragment.minY + text.textContainerOrigin.y), from: text)
        let label = String(index + 1) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
          .font: numberFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
          at: NSPoint(
            x: ruleThickness - size.width - 8,
            y: point.y + (fragment.height - size.height) / 2),
          withAttributes: attributes)
      }
      index += 1
    }
  }
}
