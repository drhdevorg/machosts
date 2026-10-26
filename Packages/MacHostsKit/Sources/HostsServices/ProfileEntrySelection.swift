import Foundation
import HostsCore

/// An immutable filter result shared by displayed controls and bulk actions.
/// Filtering matches original record text, including aliases and inline comments.
public struct ProfileEntrySelection: Sendable {
  public enum State: CaseIterable, Sendable { case all, enabled, disabled }
  public struct Row: Identifiable, Sendable {
    public let id: Int
    public let content: String
    public let isEnabled: Bool
    public let range: NSRange
  }
  public let digest: ContentDigest
  public let rows: [Row]

  public init(document: HostsDocument, query: String, state: State) {
    digest = ContentDigest(document.data)
    var offset = 0
    var matches: [Row] = []
    for line in document.lines {
      defer { offset += line.content.utf16.count + line.ending.utf16.count }
      guard case .entry(let entry) = line.kind,
        state == .all || (state == .enabled) == entry.isEnabled,
        query.isEmpty
          || line.content.range(of: query, options: [.literal, .caseInsensitive]) != nil
      else { continue }
      matches.append(
        Row(
          id: line.number, content: line.content, isEnabled: entry.isEnabled,
          range: NSRange(location: offset, length: line.content.utf16.count)))
    }
    rows = matches
  }
}
