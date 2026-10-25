import Foundation
import HostsCore

public struct ProfileSearchHit: Equatable, Sendable {
  public let profileID: UUID
  public let profileName: String
  public let digest: ContentDigest
  /// Nil identifies a profile-name match. Text positions use NSTextView's UTF-16 offsets.
  public let line: Int?
  public let range: NSRange?
  public let excerpt: String
}

public struct ProfileSearchResult: Equatable, Sendable {
  public let hits: [ProfileSearchHit]
  public let isTruncated: Bool
  public init(hits: [ProfileSearchHit], isTruncated: Bool) {
    self.hits = hits
    self.isTruncated = isTruncated
  }
}

/// Literal search on a value snapshot, away from the UI actor. Includes disabled and
/// remote drafts, excludes trash, and never mutates a workspace or opens a file.
public actor ProfileSearch {
  public init() {}

  public func search(_ query: String, in workspace: Workspace) -> ProfileSearchResult {
    guard !query.isEmpty else { return .init(hits: [], isTruncated: false) }
    let limit = 200
    var hits: [ProfileSearchHit] = []
    for profile in workspace.profiles {
      if Task.isCancelled { return .init(hits: [], isTruncated: false) }
      let digest = ContentDigest(Data(profile.source.utf8))
      if profile.name.range(of: query, options: [.caseInsensitive, .literal]) != nil {
        hits.append(
          .init(
            profileID: profile.id, profileName: profile.name, digest: digest,
            line: nil, range: nil, excerpt: profile.name))
      }
      var line = 0
      profile.source.enumerateSubstrings(in: profile.source.startIndex..., options: .byLines) {
        content, range, _, stop in
        line += 1
        if Task.isCancelled {
          stop = true
          return
        }
        if let content, let match = content.range(of: query, options: [.caseInsensitive, .literal])
        {
          let start = profile.source.utf16.distance(
            from: profile.source.utf16.startIndex,
            to: range.lowerBound)
          let local = NSRange(match, in: content)
          hits.append(
            .init(
              profileID: profile.id, profileName: profile.name, digest: digest,
              line: line,
              range: NSRange(
                location: start + local.location,
                length: local.length),
              excerpt: String(content.prefix(180))))
        }
        if hits.count > limit { stop = true }
      }
      if hits.count > limit {
        return .init(hits: Array(hits.prefix(limit)), isTruncated: true)
      }
    }
    return .init(hits: hits, isTruncated: false)
  }
}
