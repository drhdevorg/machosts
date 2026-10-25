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

/// NSTextView keeps native selection, undo and find/replace. A view identity belongs to
/// one profile so its undo stack can never modify a different profile after selection.
struct NativeProfileEditor: NSViewRepresentable {
  let source: String
  let isEditable: Bool
  let jump: ProfileEditorJump?
  let onChange: (String) -> String

  func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.borderType = .bezelBorder
    let text = ProfileTextView(frame: .zero)
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
    text.setAccessibilityIdentifier("profileSource")
    text.setAccessibilityLabel(String(localized: "Profile source"))
    text.textColor = .textColor
    text.insertionPointColor = .textColor
    text.string = source
    text.delegate = context.coordinator
    scroll.documentView = text
    scroll.verticalRulerView = ProfileLineRuler(textView: text, scrollView: scroll)
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    context.coordinator.schedulePresentation(for: text)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? ProfileTextView else { return }
    context.coordinator.onChange = onChange
    text.isEditable = isEditable
    context.coordinator.schedulePresentation(for: text, source: source)
    if text.string != source {
      let selection = text.selectedRange()
      text.string = source
      let count = (source as NSString).length
      let location = min(selection.location, count)
      text.setSelectedRange(
        NSRange(location: location, length: min(selection.length, count - location)))
      // Programmatic line switches/rejected edits invalidate older text offsets.
      text.undoManager?.removeAllActions()
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
    (scroll.documentView as? NSTextView)?.delegate = nil
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    private let styler = ProfileEditorStyler()
    private var requestedSource: String?
    var styling: Task<Void, Never>?

    func schedulePresentation(for text: NSTextView, source: String? = nil) {
      let source = source ?? text.string
      guard requestedSource != source else { return }
      requestedSource = source
      styling?.cancel()
      styling = Task { [weak text, styler] in
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        let presentation = await styler.presentation(for: source)
        guard !Task.isCancelled, let text, text.string == source else { return }
        guard let layout = text.layoutManager else { return }
        let whole = NSRange(location: 0, length: (source as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: whole)
        for span in presentation.spans where span.range.length > 0 {
          let color: NSColor
          switch span.style {
          case .address: color = .systemBlue
          case .hostname: color = .textColor
          case .comment, .disabled: color = .secondaryLabelColor
          case .invalid: color = .systemRed
          }
          layout.addTemporaryAttribute(
            .foregroundColor, value: color, forCharacterRange: span.range)
          if span.style == .invalid {
            layout.addTemporaryAttribute(
              .underlineStyle, value: NSUnderlineStyle.single.rawValue,
              forCharacterRange: span.range)
          }
        }
        (text.enclosingScrollView?.verticalRulerView as? ProfileLineRuler)?
          .update(lineStarts: presentation.lineStarts)
      }
    }
    var lastJump: UUID?
    var onChange: (String) -> String
    init(onChange: @escaping (String) -> String) { self.onChange = onChange }
    func textDidChange(_ notification: Notification) {
      guard let text = notification.object as? NSTextView else { return }
      let accepted = onChange(text.string)
      if text.string != accepted {
        let location = min(text.selectedRange().location, (accepted as NSString).length)
        text.string = accepted
        text.setSelectedRange(NSRange(location: location, length: 0))
        text.undoManager?.removeAllActions()
      }
      schedulePresentation(for: text)
    }
  }
}

/// A search can create a new profile editor before SwiftUI attaches it to a window.
private final class ProfileTextView: NSTextView {
  var focusOnAttach = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
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
    let count = (text.string as NSString).length
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
