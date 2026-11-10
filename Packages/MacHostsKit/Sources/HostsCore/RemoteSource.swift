import Foundation

public enum RemoteSourceLimits {
  public static let urlBytes = 2_048
  public static let validatorBytes = 512
  public static let redirects = 3
  public static let concurrentSources = 4
  public static let requestSeconds: Double = 30
}

/// Coarse refresh outcomes. They never contain URLs, response bodies or server messages.
public enum RemoteFetchFailure: String, Codable, Equatable, Sendable {
  case offline, timeout, tls, httpStatus, tooLarge, unsupportedEncoding, notHostsContent
  case redirectRejected, tooManyRedirects, cancelled, failed
}

/// Origin and cache metadata for read-only remote content. Profile source text remains
/// the last valid download; a failed refresh only updates the attempt fields.
public struct RemoteSource: Codable, Equatable, Sendable {
  public let url: URL
  public var entityTag: String?
  public var lastModified: String?
  /// Last 200 or 304 response that kept or replaced the content.
  public var lastRefresh: Date?
  public var lastAttempt: Date?
  public var lastFailure: RemoteFetchFailure?

  public init(
    url: URL, entityTag: String? = nil, lastModified: String? = nil, lastRefresh: Date? = nil,
    lastAttempt: Date? = nil, lastFailure: RemoteFetchFailure? = nil
  ) {
    self.url = url
    self.entityTag = entityTag
    self.lastModified = lastModified
    self.lastRefresh = lastRefresh
    self.lastAttempt = lastAttempt
    self.lastFailure = lastFailure
  }

  public func validate() throws {
    guard (try? Self.validatedURL(url.absoluteString)) == url else {
      throw WorkspaceFailure.invalidRemoteURL
    }
    for value in [entityTag, lastModified].compactMap({ $0 }) {
      guard Self.validValidator(value) else { throw WorkspaceFailure.invalidRemoteURL }
    }
  }

  /// HTTPS only, with a host and without user info. Fragments are never sent and are dropped.
  public static func validatedURL(_ text: String) throws -> URL {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= RemoteSourceLimits.urlBytes,
      var components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil
    else { throw WorkspaceFailure.invalidRemoteURL }
    components.scheme = "https"
    components.fragment = nil
    guard let url = components.url, !trimmed.unicodeScalars.contains(where: { $0.value < 33 })
    else { throw WorkspaceFailure.invalidRemoteURL }
    return url
  }

  /// A redirect target follows the same rules as a configured source.
  public static func isAllowedRedirect(_ url: URL?) -> Bool {
    guard let url else { return false }
    return (try? validatedURL(url.absoluteString)) != nil
  }

  /// Cache validators are echoed back to the server, so they must be single printable lines.
  public static func validValidator(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= RemoteSourceLimits.validatorBytes
      && value.unicodeScalars.allSatisfy { (32...126).contains($0.value) }
  }

  /// Logs and diagnostics name only the host; paths and queries may contain tokens.
  public var redactedOrigin: String { url.host() ?? "?" }
}
