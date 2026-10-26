import Foundation
import HostsCore

/// A parser line bound to the exact source bytes that produced its diagnostic.
/// Terminators are excluded so navigation never selects part of a CRLF pair.
public struct ProfileDiagnosticLocation: Equatable, Sendable {
  public let digest: ContentDigest
  public let range: NSRange

  public init?(document: HostsDocument, line number: Int?) {
    guard let number else { return nil }
    var offset = 0
    for line in document.lines {
      if line.number == number {
        digest = ContentDigest(document.data)
        range = NSRange(location: offset, length: line.content.utf16.count)
        return
      }
      offset += line.content.utf16.count + line.ending.utf16.count
    }
    return nil
  }

  init(digest: ContentDigest, range: NSRange) {
    self.digest = digest
    self.range = range
  }

  public func range(in source: String) -> NSRange? {
    ContentDigest(Data(source.utf8)) == digest ? range : nil
  }
}

/// Display-only UTF-16 positions. The parser remains the authority for valid entries;
/// colors never change source text, normalize line endings, or enter the undo stack.
public struct ProfileEditorPresentation: Equatable, Sendable {
  public enum Style: Equatable, Sendable {
    case address, hostname, comment, disabled, invalid, managed
  }
  public struct Span: Equatable, Sendable {
    public let range: NSRange
    public let style: Style
  }
  public let spans: [Span]
  /// Includes the empty editable line after a final CR, LF or CRLF, and line 1 for empty text.
  public let lineStarts: [Int]

  public static func make(source: String, system: Bool = false) -> ProfileEditorPresentation {
    let data = Data(source.utf8)
    let document = HostsDocument.parse(data, context: system ? .system : .profile)
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
      case .marker where system: spans.append(.init(range: range, style: .comment))
      case .invalid, .marker: spans.append(.init(range: range, style: .invalid))
      case .blank: break
      }
      offset += length + line.ending.utf16.count
    }
    if system,
      document.diagnostics.allSatisfy({
        $0.code != .malformedMarkers && $0.code != .lineLimit
      }), let block = document.managedBlock
    {
      let prefix = String(decoding: data.prefix(block.lowerBound), as: UTF8.self)
      let managed = String(decoding: data[block], as: UTF8.self)
      spans.append(
        .init(
          range: NSRange(location: prefix.utf16.count, length: managed.utf16.count), style: .managed
        ))
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
  public func presentation(for source: String, system: Bool = false) -> ProfileEditorPresentation {
    ProfileEditorPresentation.make(source: source, system: system)
  }
}
