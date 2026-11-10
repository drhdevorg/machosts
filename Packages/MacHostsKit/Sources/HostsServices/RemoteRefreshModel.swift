import Foundation
import HostsCore
import Observation

public struct RemoteRefreshTicket: Equatable, Sendable {
  public let profileID: UUID
  public let request: RemoteFetchRequest
  public let cachedDigest: ContentDigest
}

public enum RemoteRefreshRecord: Equatable, Sendable {
  /// New content is now the local draft; it is not applied to the system.
  case updated
  case unchanged
  case failed(RemoteFetchFailure)
  /// The source changed, moved or was deleted during the request.
  case stale
  /// The workspace refused the result (read-only or over budget); the cache is unchanged.
  case rejected
}

/// In-process refresh scheduling for remote profiles. At most four sources download at
/// once; each source has at most one request in flight. Results go through
/// `ProfileWorkspaceModel.recordRemote`, which drops stale results.
@MainActor @Observable
public final class RemoteRefreshModel {
  public private(set) var inFlight: Set<UUID> = []
  public private(set) var lastRecords: [UUID: RemoteRefreshRecord] = [:]
  @ObservationIgnored private let fetcher: RemoteProfileFetcher
  @ObservationIgnored private var queue: [UUID] = []
  @ObservationIgnored private var running = 0

  public init(fetcher: RemoteProfileFetcher = RemoteProfileFetcher()) {
    self.fetcher = fetcher
  }

  public var isRefreshing: Bool { !inFlight.isEmpty }

  public func refresh(_ id: UUID, editor: ProfileWorkspaceModel) {
    guard !editor.isReadOnly, editor.remoteTicket(id) != nil, inFlight.insert(id).inserted else {
      return
    }
    queue.append(id)
    drain(editor)
  }

  public func refreshAll(editor: ProfileWorkspaceModel) {
    for profile in editor.workspace.profiles where profile.kind == .remote {
      refresh(profile.id, editor: editor)
    }
  }

  /// Sources whose last attempt is older than the interval, or that were never tried.
  nonisolated public static func overdue(
    _ workspace: Workspace, interval: TimeInterval, now: Date = Date()
  ) -> [UUID] {
    workspace.profiles.compactMap { profile in
      guard let remote = profile.remote else { return nil }
      guard let last = remote.lastAttempt else { return profile.id }
      return now.timeIntervalSince(last) >= interval ? profile.id : nil
    }
  }

  /// Seconds until the next source becomes overdue; nil without remote sources.
  nonisolated public static func nextDue(
    _ workspace: Workspace, interval: TimeInterval, now: Date = Date()
  ) -> TimeInterval? {
    workspace.profiles.compactMap { profile -> TimeInterval? in
      guard let remote = profile.remote else { return nil }
      guard let last = remote.lastAttempt else { return 0 }
      return max(0, interval - now.timeIntervalSince(last))
    }.min()
  }

  /// Demand-driven interval refresh while the app runs. The sleep follows the continuous
  /// clock, so after system sleep each overdue source is refreshed once, not repeatedly.
  public func runSchedule(editor: ProfileWorkspaceModel, interval: TimeInterval) async {
    guard interval > 0 else { return }
    while !Task.isCancelled {
      for id in Self.overdue(editor.workspace, interval: interval) where !inFlight.contains(id) {
        refresh(id, editor: editor)
      }
      let wait = Self.nextDue(editor.workspace, interval: interval) ?? interval
      // Recheck at least hourly so edits to the source list are picked up without polling.
      let seconds = min(max(wait, 60), 3_600)
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
    }
  }

  private func drain(_ editor: ProfileWorkspaceModel) {
    while running < RemoteSourceLimits.concurrentSources, !queue.isEmpty {
      let id = queue.removeFirst()
      guard let ticket = editor.remoteTicket(id) else {
        inFlight.remove(id)
        continue
      }
      running += 1
      let fetcher = fetcher
      Task { [weak self, weak editor] in
        let outcome = await fetcher.fetch(ticket.request)
        guard let self else { return }
        self.running -= 1
        self.inFlight.remove(id)
        if let editor {
          self.lastRecords[id] = editor.recordRemote(ticket, outcome: outcome)
          self.drain(editor)
        }
      }
    }
  }
}
