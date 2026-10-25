import Foundation
import HostsCore

/// Display-only UTF-16 positions. The parser remains the authority for valid entries;
/// colors never change source text, normalize line endings, or enter the undo stack.
public struct ProfileEditorPresentation: Equatable, Sendable {
  public enum Style: Equatable, Sendable { case address, hostname, comment, disabled, invalid }
  public struct Span: Equatable, Sendable {
    public let range: NSRange
    public let style: Style
  }
  public let spans: [Span]
  /// Includes the empty editable line after a final CR, LF or CRLF, and line 1 for empty text.
  public let lineStarts: [Int]

  public static func make(source: String) -> ProfileEditorPresentation {
    let document = HostsDocument.parse(Data(source.utf8), context: .profile)
    var spans: [Span] = []
    var offset = 0
    for line in document.lines {
      let length = line.content.utf16.count
      let range = NSRange(location: offset, length: length)
      switch line.kind {
      case .entry(let entry) where !entry.isEnabled:
        spans.append(.init(range: range, style: .disabled))
      case .entry:
        let content = line.content as NSString
        let comment = content.range(of: "#")
        let end = comment.location == NSNotFound ? length : comment.location
        var first = true
        // Split only on the parser's ASCII token delimiters; punctuation belongs to IPs/hosts.
        var position = 0
        while position < end {
          if content.character(at: position) == 32 || content.character(at: position) == 9 {
            position += 1
            continue
          }
          let start = position
          while position < end && content.character(at: position) != 32
            && content.character(at: position) != 9
          { position += 1 }
          spans.append(
            .init(
              range: NSRange(location: offset + start, length: position - start),
              style: first ? .address : .hostname))
          first = false
        }
        if comment.location != NSNotFound {
          spans.append(
            .init(
              range: NSRange(
                location: offset + comment.location,
                length: length - comment.location), style: .comment))
        }
      case .comment: spans.append(.init(range: range, style: .comment))
      case .invalid, .marker: spans.append(.init(range: range, style: .invalid))
      case .blank: break
      }
      offset += length + line.ending.utf16.count
    }
    // Invalid drafts (including a BOM or too many parser lines) still need a
    // complete ruler. Do not derive the line count from a potentially partial parse.
    let units = Array(source.utf16)
    var starts = [0]
    var index = 0
    while index < units.count {
      let unit = units[index]
      index += 1
      if unit == 13 && index < units.count && units[index] == 10 { index += 1 }
      if unit == 13 || unit == 10 { starts.append(index) }
    }
    return .init(spans: spans, lineStarts: starts)
  }
}

/// Parsing and position conversion run away from the UI actor on an immutable draft.
public actor ProfileEditorStyler {
  public init() {}
  public func presentation(for source: String) -> ProfileEditorPresentation {
    ProfileEditorPresentation.make(source: source)
  }
}
