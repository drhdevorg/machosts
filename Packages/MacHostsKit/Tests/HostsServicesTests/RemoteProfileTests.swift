import Foundation
import HostsCore
import Synchronization
import Testing

@testable import HostsServices

private struct RemoteFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "machosts-remote-" + UUID().uuidString)
  func cleanup() {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Remote fixture cleanup failed")
    }
  }
}

/// Deterministic transport; records the request it received. No network access.
private final class StubTransport: RemoteTransport {
  let response: @Sendable (URLRequest) throws -> (Int, [String: String], Data)
  let requests = Mutex<[URLRequest]>([])

  init(_ response: @escaping @Sendable (URLRequest) throws -> (Int, [String: String], Data)) {
    self.response = response
  }

  func fetch(_ request: URLRequest, limit: Int) async throws -> (HTTPURLResponse, Data) {
    requests.withLock { $0.append(request) }
    let (status, headers, body) = try response(request)
    guard body.count <= limit else { throw RemoteTransportFailure.tooLarge }
    let http = try #require(
      HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)
    )
    return (http, body)
  }
}

@Test(arguments: [
  "http://example.com/hosts", "file:///etc/hosts", "https://user:secret@example.com/hosts",
  "https:///nohost", "ftp://example.com/hosts", "https://exa mple.com/hosts", "",
])
func remoteURLValidationRejectsUnsafeOrigins(_ text: String) {
  #expect(throws: WorkspaceFailure.invalidRemoteURL) { try RemoteSource.validatedURL(text) }
}

@Test func remoteURLValidationAcceptsHTTPSAndDropsFragments() throws {
  let url = try RemoteSource.validatedURL(" HTTPS://10.0.0.5:8443/lists/hosts.txt?token=x#frag ")
  #expect(url.absoluteString == "https://10.0.0.5:8443/lists/hosts.txt?token=x")
  #expect(RemoteSource(url: url).redactedOrigin == "10.0.0.5")
}

@Test func workspaceRequiresRemoteOriginExactlyForRemoteProfiles() throws {
  let url = try RemoteSource.validatedURL("https://example.com/hosts")
  let missing = Workspace(profiles: [Profile(name: "R", kind: .remote)])
  #expect(throws: WorkspaceFailure.invalidRemoteURL) { try missing.validate() }
  let localWithOrigin = Workspace(profiles: [Profile(name: "L", remote: RemoteSource(url: url))])
  #expect(throws: WorkspaceFailure.invalidRemoteURL) { try localWithOrigin.validate() }
  let valid = Workspace(profiles: [Profile(name: "R", kind: .remote, remote: .init(url: url))])
  try valid.validate()
}

@Test func fetcherSendsValidatorsAndKeepsThemOn304() async throws {
  let transport = StubTransport { _ in (304, [:], Data()) }
  let fetcher = RemoteProfileFetcher(transport: transport)
  let source = RemoteSource(
    url: try RemoteSource.validatedURL("https://example.com/hosts"), entityTag: "\"v1\"",
    lastModified: "Tue, 10 Nov 2026 10:00:00 GMT")
  let outcome = await fetcher.fetch(RemoteFetchRequest(source: source))
  #expect(
    outcome == .notModified(entityTag: "\"v1\"", lastModified: "Tue, 10 Nov 2026 10:00:00 GMT"))
  let sent = try #require(transport.requests.withLock { $0.first })
  #expect(sent.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
  #expect(sent.value(forHTTPHeaderField: "If-Modified-Since") != nil)
  #expect(sent.httpShouldHandleCookies == false)
  #expect(sent.timeoutInterval == RemoteSourceLimits.requestSeconds)
}

@Test func fetcherRejectsContentThatMustNotReplaceTheCache() async throws {
  let url = try RemoteSource.validatedURL("https://example.com/hosts")
  let cases: [(Int, Data, RemoteFetchFailure)] = [
    (500, Data(), .httpStatus),
    (200, Data([0xFF, 0xFE, 0x00]), .unsupportedEncoding),
    (200, Data("<html><body>Sign in to Wi-Fi</body></html>\n".utf8), .notHostsContent),
    (200, Data(repeating: 0x23, count: HostsLimits.profileBytes + 1), .tooLarge),
  ]
  for (status, body, expected) in cases {
    let fetcher = RemoteProfileFetcher(transport: StubTransport { _ in (status, [:], body) })
    #expect(await fetcher.fetch(RemoteFetchRequest(source: .init(url: url))) == .failure(expected))
  }
}

@Test func fetcherAcceptsHostsTextAndIgnoresUnsafeValidators() async throws {
  let url = try RemoteSource.validatedURL("https://example.com/hosts")
  let body = Data("# list\n192.0.2.7 ads.example\n".utf8)
  let fetcher = RemoteProfileFetcher(
    transport: StubTransport { _ in (200, ["ETag": "\"abc\"", "Last-Modified": "bad\u{7}"], body) })
  let outcome = await fetcher.fetch(RemoteFetchRequest(source: .init(url: url)))
  #expect(
    outcome
      == .content(
        source: "# list\n192.0.2.7 ads.example\n", entityTag: "\"abc\"", lastModified: nil))
}

@Test func transportErrorsMapToCoarseCategories() {
  #expect(RemoteProfileFetcher.category(URLError(.notConnectedToInternet)) == .offline)
  #expect(RemoteProfileFetcher.category(URLError(.timedOut)) == .timeout)
  #expect(RemoteProfileFetcher.category(URLError(.serverCertificateUntrusted)) == .tls)
  #expect(
    RemoteProfileFetcher.category(RemoteTransportFailure.tooManyRedirects) == .tooManyRedirects)
  #expect(
    RemoteProfileFetcher.category(RemoteTransportFailure.redirectRejected) == .redirectRejected)
  #expect(RemoteProfileFetcher.category(CancellationError()) == .cancelled)
}

@Test @MainActor func remoteRefreshStoresValidContentAsInactiveDraftOnly() async throws {
  let fixture = RemoteFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let id = try #require(model.addRemote(name: "Blocklist", url: "https://example.com/hosts"))
  #expect(model.workspace.profiles[0].kind == .remote && !model.workspace.profiles[0].isEnabled)
  let ticket = try #require(model.remoteTicket(id))
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  let record = model.recordRemote(
    ticket,
    outcome: .content(source: "192.0.2.9 a.example\n", entityTag: "\"1\"", lastModified: nil),
    at: date)
  #expect(record == .updated)
  let profile = model.workspace.profiles[0]
  #expect(profile.source == "192.0.2.9 a.example\n" && !profile.isEnabled)
  #expect(profile.remote?.lastRefresh == date && profile.remote?.entityTag == "\"1\"")
  #expect(model.persisted.snapshot?.applied == nil)
  #expect(await model.flush())
  let reopened = try await WorkspaceStore.open(directory: fixture.directory)
  #expect(await reopened.state().snapshot?.draft.profiles[0].remote?.entityTag == "\"1\"")
}

@Test @MainActor func failedRefreshKeepsLastValidContent() async throws {
  let fixture = RemoteFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let id = try #require(model.addRemote(name: "List", url: "https://example.com/hosts"))
  model.recordRemote(
    try #require(model.remoteTicket(id)),
    outcome: .content(source: "192.0.2.1 keep.example\n", entityTag: nil, lastModified: nil))
  let record = model.recordRemote(try #require(model.remoteTicket(id)), outcome: .failure(.offline))
  #expect(record == .failed(.offline))
  #expect(model.workspace.profiles[0].source == "192.0.2.1 keep.example\n")
  #expect(model.workspace.profiles[0].remote?.lastFailure == .offline)
  #expect(model.workspace.profiles[0].remote?.lastRefresh != nil)
}

@Test @MainActor func staleRefreshResultsAreDropped() async throws {
  let fixture = RemoteFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let id = try #require(model.addRemote(name: "List", url: "https://example.com/a"))
  let ticket = try #require(model.remoteTicket(id))
  model.setRemoteURL(id, url: "https://example.com/b")
  let result = model.recordRemote(
    ticket, outcome: .content(source: "192.0.2.2 old.example\n", entityTag: nil, lastModified: nil))
  #expect(result == .stale)
  #expect(model.workspace.profiles[0].source.isEmpty)
  let deleted = try #require(model.remoteTicket(id))
  model.delete(id)
  #expect(model.recordRemote(deleted, outcome: .failure(.timeout)) == .stale)
  #expect(model.workspace.trash[0].profile.remote?.lastFailure == nil)
}

@Test @MainActor func changingRemoteURLDiscardsCachedContentAndValidators() async throws {
  let fixture = RemoteFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let id = try #require(model.addRemote(name: "List", url: "https://example.com/a"))
  model.recordRemote(
    try #require(model.remoteTicket(id)),
    outcome: .content(source: "192.0.2.3 a.example\n", entityTag: "\"a\"", lastModified: nil))
  model.setRemoteURL(id, url: "https://example.org/b")
  let profile = model.workspace.profiles[0]
  #expect(profile.source.isEmpty && profile.remote?.entityTag == nil)
  #expect(profile.remote?.url.absoluteString == "https://example.org/b")
  model.setRemoteURL(id, url: "http://example.org/b")
  #expect(model.editFailure == .invalidRemoteURL)
  #expect(model.workspace.profiles[0].remote?.url.absoluteString == "https://example.org/b")
  #expect(model.addRemote(name: "Bad", url: "file:///etc/hosts") == nil)
}

@Test @MainActor func remoteContentIsReadOnlyAndDuplicatesAsLocal() async throws {
  let fixture = RemoteFixture()
  defer { fixture.cleanup() }
  let store = try await WorkspaceStore.open(directory: fixture.directory)
  let model = try await ProfileWorkspaceModel.open(store: store, delay: .seconds(60))
  let id = try #require(model.addRemote(name: "List", url: "https://example.com/a"))
  model.recordRemote(
    try #require(model.remoteTicket(id)),
    outcome: .content(source: "192.0.2.4 r.example\n", entityTag: nil, lastModified: nil))
  model.setSource(id, source: "edited")
  #expect(model.editFailure == .readOnlyProfile)
  let copy = try #require(model.duplicate(id, name: "Local copy"))
  let local = try #require(model.workspace.profiles.first { $0.id == copy })
  #expect(local.kind == .local && local.remote == nil && local.source == "192.0.2.4 r.example\n")
}

@Test func refreshMetadataIsNotAnUnappliedChange() throws {
  let url = try RemoteSource.validatedURL("https://example.com/hosts")
  let base = Workspace(
    profiles: [Profile(name: "R", kind: .remote, source: "x", remote: .init(url: url))])
  var refreshed = base
  refreshed.revision = 9
  refreshed.profiles[0].revision = 4
  refreshed.profiles[0].remote?.lastAttempt = Date()
  refreshed.profiles[0].remote?.entityTag = "\"z\""
  #expect(refreshed.withoutRemoteStatus == base.withoutRemoteStatus)
  refreshed.profiles[0].source = "y"
  #expect(refreshed.withoutRemoteStatus != base.withoutRemoteStatus)
}

@Test func scheduleSelectsOnlyOverdueSources() throws {
  let now = Date(timeIntervalSince1970: 2_000_000_000)
  let url = try RemoteSource.validatedURL("https://example.com/hosts")
  let fresh = Profile(
    name: "Fresh", kind: .remote, remote: .init(url: url, lastAttempt: now.addingTimeInterval(-60)))
  let stale = Profile(
    name: "Stale", kind: .remote,
    remote: .init(url: url, lastAttempt: now.addingTimeInterval(-7_200)))
  let never = Profile(name: "Never", kind: .remote, remote: .init(url: url))
  let workspace = Workspace(profiles: [fresh, stale, never, Profile(name: "Local")])
  #expect(
    RemoteRefreshModel.overdue(workspace, interval: 3_600, now: now) == [stale.id, never.id])
  #expect(RemoteRefreshModel.nextDue(workspace, interval: 3_600, now: now) == 0)
  let onlyFresh = Workspace(profiles: [fresh])
  #expect(RemoteRefreshModel.nextDue(onlyFresh, interval: 3_600, now: now) == 3_540)
}

@Test func diagnosticReportContainsNoNamesSourcesOrURLs() throws {
  let url = try RemoteSource.validatedURL("https://secret-host.example/path?token=abc")
  let workspace = Workspace(profiles: [
    Profile(name: "Private name", source: "192.0.2.5 private.example\n", isEnabled: true),
    Profile(
      name: "Remote", kind: .remote, source: "",
      remote: .init(url: url, lastFailure: .tls)),
  ])
  let report = DiagnosticReport(
    environment: .init(appVersion: "0.1.0", build: "1", operatingSystem: "test"),
    load: nil, draft: workspace, unsavedChanges: false, systemStatus: .unconfirmed,
    observationFailure: nil, systemDiagnostics: nil, loginItem: "notRegistered")
  for secret in ["Private name", "private.example", "secret-host", "token", "192.0.2.5"] {
    #expect(!report.text.contains(secret))
  }
  #expect(report.text.contains("remote.failure.tls: 1"))
  #expect(report.text.contains("profiles: 2 (1 desired active, 1 remote)"))
}
