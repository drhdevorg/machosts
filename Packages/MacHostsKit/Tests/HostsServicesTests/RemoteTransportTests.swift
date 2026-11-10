import Foundation
import HostsCore
import Synchronization
import Testing

@testable import HostsServices

/// What the in-process URL loader does for one request. Nothing leaves the process:
/// requests are answered by `LocalHTTPProtocol` inside the real URLSession pipeline,
/// so redirect delegates, streaming and error propagation run unmodified.
private enum LoaderStep: Sendable {
  case respond(status: Int, headers: [String: String], chunks: [Data])
  case redirect(to: String)
  case fail(URLError.Code)
  case hang
}

private final class LocalHTTPProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) -> LoaderStep
  private static let handlers = Mutex<[String: Handler]>([:])
  private static let seen = Mutex<[String: [URLRequest]]>([:])

  /// Each test uses its own host so parallel tests never share a handler.
  static func register(_ handler: @escaping Handler) -> String {
    let host = "t" + UUID().uuidString.lowercased().prefix(12) + ".example"
    handlers.withLock { $0[host] = handler }
    return host
  }

  static func requests(_ host: String) -> [URLRequest] {
    seen.withLock { $0[host] ?? [] }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let host = url.host,
      let handler = Self.handlers.withLock({ $0[host] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    Self.seen.withLock { $0[host, default: []].append(request) }
    switch handler(request) {
    case .respond(let status, let headers, let chunks):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
      client?.urlProtocolDidFinishLoading(self)
    case .redirect(let location):
      let target = URL(string: location, relativeTo: url)!.absoluteURL
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString])!
      // Like a loader that carries request headers across hops; the policy must strip them.
      var next = request
      next.url = target
      client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    case .fail(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .hang:
      break
    }
  }

  override func stopLoading() {}
}

private let transport = URLSessionRemoteTransport(protocolClasses: [LocalHTTPProtocol.self])
private let fetcher = RemoteProfileFetcher(transport: transport)

private func request(_ host: String, _ path: String = "/hosts") -> RemoteFetchRequest {
  RemoteFetchRequest(source: RemoteSource(url: URL(string: "https://\(host)\(path)")!))
}

private func ok(_ text: String, headers: [String: String] = [:]) -> LoaderStep {
  .respond(status: 200, headers: headers, chunks: [Data(text.utf8)])
}

@Test func sessionTransportDeliversContentAndValidators() async throws {
  let host = LocalHTTPProtocol.register { _ in
    ok("127.0.0.1 a.test\n", headers: ["ETag": "\"v1\"", "Last-Modified": "Tue, 10 Nov 2026"])
  }
  let outcome = await fetcher.fetch(request(host))
  #expect(
    outcome
      == .content(
        source: "127.0.0.1 a.test\n", entityTag: "\"v1\"", lastModified: "Tue, 10 Nov 2026"))
  let sent = try #require(LocalHTTPProtocol.requests(host).first)
  #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
  #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func sessionTransportFollowsHTTPSRedirectsWithoutCredentials() async throws {
  let host = LocalHTTPProtocol.register { request in
    switch request.url?.path {
    case "/a": .redirect(to: "/b")
    case "/b": .redirect(to: "/c")
    default: ok("10.0.0.1 b.test\n")
    }
  }
  var raw = URLRequest(url: URL(string: "https://\(host)/a")!)
  raw.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
  raw.setValue("session=1", forHTTPHeaderField: "Cookie")
  let (response, body) = try await transport.fetch(raw, limit: HostsLimits.profileBytes)
  #expect(response.statusCode == 200)
  #expect(String(decoding: body, as: UTF8.self) == "10.0.0.1 b.test\n")
  let seen = LocalHTTPProtocol.requests(host)
  #expect(seen.map(\.url?.path) == ["/a", "/b", "/c"])
  for hop in seen.dropFirst() {
    #expect(hop.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(hop.value(forHTTPHeaderField: "Cookie") == nil)
  }
}

@Test func sessionTransportRejectsUnsafeRedirects() async throws {
  let downgrade = LocalHTTPProtocol.register { _ in .redirect(to: "http://plain.example/hosts") }
  #expect(await fetcher.fetch(request(downgrade)) == .failure(.redirectRejected))

  let userInfo = LocalHTTPProtocol.register { request in
    .redirect(to: "https://user:pw@\(request.url!.host!)/next")
  }
  #expect(await fetcher.fetch(request(userInfo)) == .failure(.redirectRejected))
  #expect(LocalHTTPProtocol.requests(userInfo).count == 1)

  let loop = LocalHTTPProtocol.register { request in
    .redirect(to: "/\((Int(request.url!.lastPathComponent) ?? 0) + 1)")
  }
  #expect(await fetcher.fetch(request(loop, "/0")) == .failure(.tooManyRedirects))
  // The original request plus three permitted hops; the fourth is never loaded.
  #expect(LocalHTTPProtocol.requests(loop).count == 1 + RemoteSourceLimits.redirects)
}

@Test func sessionTransportRefusesNonHTTPSBeforeLoading() async throws {
  let host = LocalHTTPProtocol.register { _ in ok("1.1.1.1 x.test\n") }
  let raw = URLRequest(url: URL(string: "http://\(host)/hosts")!)
  await #expect(throws: RemoteTransportFailure.redirectRejected) {
    _ = try await transport.fetch(raw, limit: HostsLimits.profileBytes)
  }
  #expect(LocalHTTPProtocol.requests(host).isEmpty)
}

@Test func sessionTransportBoundsBodiesWhileStreaming() async throws {
  let chunk = Data(repeating: UInt8(ascii: "#"), count: 64 * 1024)
  let count = HostsLimits.profileBytes / chunk.count + 2
  let streamed = LocalHTTPProtocol.register { _ in
    .respond(status: 200, headers: [:], chunks: Array(repeating: chunk, count: count))
  }
  #expect(await fetcher.fetch(request(streamed)) == .failure(.tooLarge))

  let declared = LocalHTTPProtocol.register { _ in
    .respond(
      status: 200, headers: ["Content-Length": String(HostsLimits.profileBytes + 1)],
      chunks: [Data("1.1.1.1 x.test\n".utf8)])
  }
  #expect(await fetcher.fetch(request(declared)) == .failure(.tooLarge))

  let exact = LocalHTTPProtocol.register { _ in
    .respond(
      status: 200, headers: [:],
      chunks: [Data(repeating: UInt8(ascii: "#"), count: HostsLimits.profileBytes)])
  }
  if case .content(let source, _, _) = await fetcher.fetch(request(exact)) {
    #expect(source.utf8.count == HostsLimits.profileBytes)
  } else {
    Issue.record("A body at exactly the limit must be accepted")
  }
}

@Test func sessionTransportReportsStatusAndLoaderFailures() async throws {
  let status = LocalHTTPProtocol.register { _ in
    .respond(status: 503, headers: [:], chunks: [Data("<html>busy</html>".utf8)])
  }
  #expect(await fetcher.fetch(request(status)) == .failure(.httpStatus))

  let cases: [(URLError.Code, RemoteFetchFailure)] = [
    (.serverCertificateUntrusted, .tls), (.secureConnectionFailed, .tls),
    (.timedOut, .timeout), (.notConnectedToInternet, .offline),
  ]
  for (code, expected) in cases {
    let host = LocalHTTPProtocol.register { _ in .fail(code) }
    #expect(await fetcher.fetch(request(host)) == .failure(expected))
  }
}

@Test func sessionTransportCancelsInFlightRequests() async throws {
  let host = LocalHTTPProtocol.register { _ in .hang }
  let task = Task { await fetcher.fetch(request(host)) }
  while LocalHTTPProtocol.requests(host).isEmpty { await Task.yield() }
  task.cancel()
  #expect(await task.value == .failure(.cancelled))
}
