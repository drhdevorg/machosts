import Foundation
import HostsCore
import Observation

/// UI state for read-only observation. Only the coordinator may reconcile a pending apply.
@MainActor @Observable
public final class SystemObservationModel {
  /// Invalidates frozen previews even if a restart or transient read failure returns equal bytes.
  public private(set) var previewRevision: UInt64 = 0
  public private(set) var contents: SystemFileContents?
  public private(set) var observation: SystemFileObservation?
  public private(set) var isMonitoring = false
  public private(set) var workspaceUnavailable = true
  public private(set) var workspaceReadOnlyReason: WorkspaceRecoveryReason?
  private var appliedDigest: ContentDigest?
  private var pendingApply: PendingApply?
  @ObservationIgnored private let monitor: SystemFileMonitor
  @ObservationIgnored private var generation: UInt64 = 0

  public init() { monitor = SystemFileMonitor() }

  init(monitor: SystemFileMonitor) { self.monitor = monitor }

  public var status: SystemObservation {
    if pendingApply != nil { return .recoveryRequired }
    guard !workspaceUnavailable, workspaceReadOnlyReason == nil, isMonitoring,
      let observation
    else { return .unconfirmed }
    return observation.status(appliedDigest: appliedDigest, hasPendingApply: false)
  }

  /// Observation alone cannot resolve an intent, including one with exactly matching bytes.
  public var pendingFileState: PendingApplyFileState? {
    guard let pendingApply else { return nil }
    let digest: ContentDigest?
    if isMonitoring, case .readable(let value) = observation {
      digest = value
    } else {
      digest = nil
    }
    return PendingApplyFileState(pending: pendingApply, digest: digest)
  }

  /// Call after every persisted workspace change, even if the file digest has not changed.
  /// Read-only/corrupt workspace data must never establish a confirmed current state.
  public func updateWorkspace(_ load: WorkspaceLoad?) {
    workspaceUnavailable = load?.snapshot == nil
    workspaceReadOnlyReason = load?.readOnlyReason
    appliedDigest = load?.snapshot?.applied?.receipt.afterDigest
    pendingApply = load?.snapshot?.pendingApply
  }

  /// Keep this task alive for the observation lifetime. A replacement run invalidates all
  /// older continuations; cancellation releases Dispatch watches through stream termination.
  public func run() async {
    previewRevision &+= 1
    generation &+= 1
    let token = generation
    contents = nil
    observation = nil
    isMonitoring = false
    do {
      try Task.checkCancellation()
      let stream = try await monitor.start()
      guard token == generation, !Task.isCancelled else { return }
      isMonitoring = true
      for await value in stream {
        guard token == generation, !Task.isCancelled else { break }
        let currentContents = await monitor.contents(matching: value)
        guard token == generation, !Task.isCancelled else { break }
        if observation != value { previewRevision &+= 1 }
        contents = currentContents
        observation = value
      }
    } catch let failure as SystemFileReadFailure {
      if token == generation { observation = .unreadable(failure) }
    } catch {
      if token == generation, !Task.isCancelled { observation = .unreadable(.unavailable) }
    }
    if token == generation {
      previewRevision &+= 1
      isMonitoring = false
      contents = nil
      // A past successful read is not a live confirmation after observation has stopped.
      if Task.isCancelled { observation = nil }
    }
  }

  public func refresh() async { await monitor.refresh() }
}
