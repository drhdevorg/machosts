import Foundation
import HostsCore

public struct WorkspaceAutosaveState: Sendable {
  public let savedGeneration: UInt64
  public let pendingRevision: UInt64?
  public let lastFailure: (any Error)?
}

/// Debounces drafts while retaining unsaved content after every error. Explicit flush drains
/// the latest draft and joins an in-progress save; cancellation of a timer never cancels a commit.
public actor WorkspaceAutosave {
  private let store: WorkspaceStore
  private let delay: Duration
  private var saved: WorkspaceSnapshot
  private var pending: Workspace?
  private var timer: Task<Void, Never>?
  private var inFlight: (id: UUID, draft: Workspace, task: Task<WorkspaceSnapshot, any Error>)?
  private var lastFailure: (any Error)?

  private init(store: WorkspaceStore, snapshot: WorkspaceSnapshot, delay: Duration) {
    self.store = store
    saved = snapshot
    self.delay = delay
  }

  public static func open(store: WorkspaceStore, delay: Duration = .milliseconds(350)) async throws
    -> WorkspaceAutosave
  {
    let load = await store.state()
    guard load.readOnlyReason == nil, let snapshot = load.snapshot else {
      throw WorkspaceStoreFailure.readOnly
    }
    return WorkspaceAutosave(store: store, snapshot: snapshot, delay: delay)
  }

  deinit { timer?.cancel() }

  public func schedule(_ draft: Workspace) throws {
    try draft.validate()
    let latest = pending ?? inFlight?.draft ?? saved.draft
    guard draft != latest else { return }
    guard draft.revision > latest.revision else { throw WorkspaceStoreFailure.staleRevision }
    pending = draft
    lastFailure = nil
    timer?.cancel()
    let delay = delay
    timer = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
        try await self?.flush()
      } catch is CancellationError {
        // Replaced debounce timers are expected; commit tasks are independent.
      } catch {
        // flush has already retained the draft and recorded its error on this actor.
      }
    }
  }

  public func state() -> WorkspaceAutosaveState {
    .init(
      savedGeneration: saved.generation,
      pendingRevision: pending?.revision ?? inFlight?.draft.revision, lastFailure: lastFailure)
  }

  public func flush() async throws {
    while pending != nil || inFlight != nil {
      if inFlight == nil, let draft = pending {
        let baseline = saved.draft
        let store = store
        pending = nil
        inFlight = (
          UUID(), draft,
          Task {
            let load = await store.state()
            guard let snapshot = load.snapshot, snapshot.draft == baseline else {
              throw WorkspaceStoreFailure.staleGeneration
            }
            return try await store.saveDraft(draft, expectedGeneration: snapshot.generation)
          }
        )
      }
      guard let flight = inFlight else { return }
      do {
        let result = try await flight.task.value
        if inFlight?.id == flight.id {
          saved = result
          inFlight = nil
          lastFailure = nil
        }
      } catch {
        if inFlight?.id == flight.id {
          inFlight = nil
          if pending == nil || (pending?.revision ?? 0) < flight.draft.revision {
            pending = flight.draft
          }
          lastFailure = error
        }
        throw error
      }
    }
  }

}
