import Foundation
import HostsCore
import Synchronization

/// Validated download result. Content has already passed the same encoding and line
/// limits as a local import, so it may replace the last valid cache.
public enum RemoteFetchOutcome: Equatable, Sendable {
  case content(source: String, entityTag: String?, lastModified: String?)
  case notModified(entityTag: String?, lastModified: String?)
  case failure(RemoteFetchFailure)
}

public struct RemoteFetchRequest: Equatable, Sendable {
  public let url: URL
  public let entityTag: String?
  public let lastModified: String?

  public init(source: RemoteSource) {
    url = source.url
    entityTag = source.entityTag
    lastModified = source.lastModified
  }
}

/// Raw transport boundary. Implementations must bound the body while streaming.
public protocol RemoteTransport: Sendable {
  func fetch(_ request: URLRequest, limit: Int) async throws -> (HTTPURLResponse, Data)
}

public enum RemoteTransportFailure: Error, Equatable, Sendable {
  case tooLarge, redirectRejected, tooManyRedirects, notHTTP
}

/// Converts transport results into cache-safe outcomes. Nothing here touches the workspace.
public struct RemoteProfileFetcher: Sendable {
  private let transport: any RemoteTransport

  public init(transport: any RemoteTransport = URLSessionRemoteTransport()) {
    self.transport = transport
  }

  public func fetch(_ request: RemoteFetchRequest) async -> RemoteFetchOutcome {
    var urlRequest = URLRequest(
      url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: RemoteSourceLimits.requestSeconds)
    urlRequest.httpShouldHandleCookies = false
    urlRequest.setValue("text/plain, */*;q=0.5", forHTTPHeaderField: "Accept")
    if let tag = request.entityTag, RemoteSource.validValidator(tag) {
      urlRequest.setValue(tag, forHTTPHeaderField: "If-None-Match")
    }
    if let date = request.lastModified, RemoteSource.validValidator(date) {
      urlRequest.setValue(date, forHTTPHeaderField: "If-Modified-Since")
    }
    let response: HTTPURLResponse
    let body: Data
    do {
      (response, body) = try await transport.fetch(urlRequest, limit: HostsLimits.profileBytes)
    } catch {
      return .failure(Self.category(error))
    }
    let tag = Self.validator(response, "ETag")
    let modified = Self.validator(response, "Last-Modified")
    switch response.statusCode {
    case 304:
      // Keep known validators when a 304 omits them.
      return .notModified(
        entityTag: tag ?? request.entityTag, lastModified: modified ?? request.lastModified)
    case 200:
      return Self.validate(body, entityTag: tag, lastModified: modified)
    default:
      return .failure(.httpStatus)
    }
  }

  static func validate(_ body: Data, entityTag: String?, lastModified: String?)
    -> RemoteFetchOutcome
  {
    let snapshot: HostsTextImport
    do { snapshot = try HostsTextImport(data: body) } catch {
      switch error as? HostsTextExchangeFailure {
      case .sizeLimit: return .failure(.tooLarge)
      case .unsupportedEncoding: return .failure(.unsupportedEncoding)
      default: return .failure(.notHostsContent)
      }
    }
    // A captive portal or error page must not replace a valid cache. Comment-only
    // and empty lists stay valid; content without any entry but with invalid lines does not.
    let lines = snapshot.document.lines
    let hasEntry = lines.contains { if case .entry = $0.kind { true } else { false } }
    let hasInvalid = lines.contains { if case .invalid = $0.kind { true } else { false } }
    if hasInvalid && !hasEntry { return .failure(.notHostsContent) }
    return .content(source: snapshot.source, entityTag: entityTag, lastModified: lastModified)
  }

  private static func validator(_ response: HTTPURLResponse, _ name: String) -> String? {
    guard let value = response.value(forHTTPHeaderField: name), RemoteSource.validValidator(value)
    else { return nil }
    return value
  }

  static func category(_ error: any Error) -> RemoteFetchFailure {
    if let failure = error as? RemoteTransportFailure {
      switch failure {
      case .tooLarge: return .tooLarge
      case .redirectRejected: return .redirectRejected
      case .tooManyRedirects: return .tooManyRedirects
      case .notHTTP: return .failed
      }
    }
    if error is CancellationError { return .cancelled }
    guard let error = error as? URLError else { return .failed }
    switch error.code {
    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
      return .offline
    case .timedOut: return .timeout
    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
      .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
      .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
      return .tls
    case .cancelled: return .cancelled
    case .httpTooManyRedirects: return .tooManyRedirects
    case .dataLengthExceedsMaximum: return .tooLarge
    default: return .failed
    }
  }
}

/// Ephemeral, credential-free URLSession transport with normal system TLS validation.
public final class URLSessionRemoteTransport: RemoteTransport {
  private let session: URLSession

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = RemoteSourceLimits.requestSeconds
    configuration.timeoutIntervalForResource = RemoteSourceLimits.requestSeconds
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 2
    session = URLSession(configuration: configuration)
  }

  public func fetch(_ request: URLRequest, limit: Int) async throws -> (HTTPURLResponse, Data) {
    guard RemoteSource.isAllowedRedirect(request.url) else {
      throw RemoteTransportFailure.redirectRejected
    }
    let policy = RedirectPolicy()
    let (bytes, response) = try await session.bytes(for: request, delegate: policy)
    // A refused redirect ends the task with the 3xx response; report the refusal instead.
    if let rejection = policy.rejection { throw rejection }
    guard let http = response as? HTTPURLResponse else { throw RemoteTransportFailure.notHTTP }
    if http.statusCode != 200 { return (http, Data()) }
    if http.expectedContentLength > Int64(limit) { throw RemoteTransportFailure.tooLarge }
    var data = Data()
    data.reserveCapacity(
      Int(min(max(http.expectedContentLength, 0), Int64(limit))))
    for try await byte in bytes {
      guard data.count < limit else { throw RemoteTransportFailure.tooLarge }
      data.append(byte)
    }
    return (http, data)
  }
}

/// Per-task redirect validation: HTTPS only, no user info, at most three hops.
/// Cross-host redirects carry no credentials because none are ever attached.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  private let state = Mutex<(hops: Int, rejection: RemoteTransportFailure?)>((0, nil))

  var rejection: RemoteTransportFailure? { state.withLock { $0.rejection } }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    let allowed = state.withLock { value -> Bool in
      value.hops += 1
      if value.hops > RemoteSourceLimits.redirects {
        value.rejection = .tooManyRedirects
      } else if !RemoteSource.isAllowedRedirect(request.url) {
        value.rejection = .redirectRejected
      }
      return value.rejection == nil
    }
    guard allowed else { return nil }
    var next = request
    next.setValue(nil, forHTTPHeaderField: "Authorization")
    next.setValue(nil, forHTTPHeaderField: "Cookie")
    return next
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    // Server trust uses default system evaluation; no credentials are ever offered.
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      return (.performDefaultHandling, nil)
    }
    return (.rejectProtectionSpace, nil)
  }
}
