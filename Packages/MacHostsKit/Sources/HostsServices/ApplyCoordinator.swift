import Foundation
import HostsCore

public enum ApplyCoordinatorFailure: Error, Equatable, Sendable {
  case integrationUnavailable, busy, stalePlan, recoveryRequired, cancelled, notCommitted
  case unverifiedResult
}

public enum ApplyState: Equatable, Sendable {
  case idle, preparing
  case previewReady(UUID)
  case authorizing(UUID)
  case committing(UUID)
  case verifying(UUID)
  case unchanged
  case applied(ApplyReceipt)
  case cancelled, failed, recoveryRequired
}

public enum SystemObservation: Equatable, Sendable {
  case unconfirmed, confirmed, externalChange, recoveryRequired
}

enum ApplyTransactionOutcome: Sendable {
  /// Authoritative terminal result: no tool can still commit this transaction.
  case notCommitted
  case retired(ApplyRetirement)
  case committed(ApplyReceipt)
  /// Checked under the worker lock. Absence is not terminal non-commit evidence.
  case missingJournal
  case workerActive
  case unknown
}

/// Internal integration seam. Only tests currently implement it; no selectable production
/// fixture path or simulated success is exposed by the app or command-line tool.
protocol ApplyEnvironment: Sendable {
  func readSystem() async throws -> Data
  func authorize(_ planID: UUID) async throws
  /// The adapter must independently revalidate the plan and journal its own file transaction.
  /// Only notCommitted promises that no commit began; every other error has an unknown outcome.
  func commit(_ plan: ApplyPlan) async throws -> ApplyReceipt
  /// Inspect/reconcile independent records while excluding any worker that could still commit.
  /// A held worker lock yields workerActive; absent records yield missingJournal, never notCommitted.
  /// This must not restore target bytes or repeat the original request.
  func outcome(for transactionID: UUID) async throws -> ApplyTransactionOutcome
  /// Persist a fence under the worker lock, excluding every future commit for this ID.
  /// Only journal-less intents with unchanged before-bytes may be retired. Never writes target bytes.
  func retireOrphan(_ retirement: ApplyRetirement) async throws -> ApplyRetirement
}

extension ApplyEnvironment {
  func retireOrphan(_ retirement: ApplyRetirement) async throws -> ApplyRetirement {
    throw ApplyCoordinatorFailure.integrationUnavailable
  }
}

private struct UnavailableApplyEnvironment: ApplyEnvironment {
  func readSystem() throws -> Data { throw ApplyCoordinatorFailure.integrationUnavailable }
  func authorize(_ planID: UUID) throws { throw ApplyCoordinatorFailure.integrationUnavailable }
  func commit(_ plan: ApplyPlan) throws -> ApplyReceipt {
    throw ApplyCoordinatorFailure.integrationUnavailable
  }
  func outcome(for transactionID: UUID) throws -> ApplyTransactionOutcome {
    throw ApplyCoordinatorFailure.integrationUnavailable
  }
}

/// Serializes preview/authorization/commit across suspension points. The workspace store's
/// process lock serializes cooperating app instances. Production integration stays unavailable.
public actor ApplyCoordinator {
  private let store: WorkspaceStore
  private let environment: any ApplyEnvironment
  private var currentState: ApplyState = .idle
  private var busy = false
  private var preview: (workspace: Workspace, plan: ApplyPlan)?
  private var lastRecoveryAssessment: ApplyRecoveryAssessment?

  public init(store: WorkspaceStore) {
    self.store = store
    environment = UnavailableApplyEnvironment()
  }

  init(store: WorkspaceStore, environment: any ApplyEnvironment) {
    self.store = store
    self.environment = environment
  }

  public func state() async -> ApplyState {
    if currentState == .idle, await store.state().snapshot?.pendingApply != nil {
      return .recoveryRequired
    }
    return currentState
  }

  /// Diagnostic snapshot of the last attempt, not a capability to resolve or dismiss an intent.
  public func recoveryAssessment() -> ApplyRecoveryAssessment? { lastRecoveryAssessment }

  /// Flush editor/autosave changes before preparing. Only persisted drafts can be applied.
  public func prepare() async throws -> ApplyPlan {
    try enter()
    defer { busy = false }
    preview = nil
    lastRecoveryAssessment = nil
    currentState = .preparing
    do {
      let snapshot = try await writableSnapshot()
      guard snapshot.pendingApply == nil else { throw ApplyCoordinatorFailure.recoveryRequired }
      let system = try await environment.readSystem()
      try Task.checkCancellation()
      let fresh = try await writableSnapshot()
      guard snapshot.generation == fresh.generation else { throw ApplyCoordinatorFailure.stalePlan }
      let document = HostsDocument.parse(system, context: .system)
      let actualManaged = document.managedBlock.map { ContentDigest(system.subdata(in: $0)) }
      if let applied = fresh.applied {
        if let expected = applied.managedDigest {
          guard actualManaged == expected else { throw PlanFailure.managedBlockChanged }
        } else if ContentDigest(system) != applied.receipt.afterDigest,
          actualManaged != nil || applied.separatorEvidence != nil
        {
          // Legacy receipts have no independent block digest; require an exact file match.
          throw PlanFailure.managedBlockChanged
        }
      } else if actualManaged != nil {
        throw PlanFailure.managedBlockChanged
      }
      let plan = try ApplyPlan.prepare(
        workspace: fresh.draft, system: system,
        expectedManagedDigest: fresh.applied?.managedDigest,
        separatorEvidence: fresh.applied?.separatorEvidence)
      preview = (fresh.draft, plan)
      currentState = .previewReady(plan.id)
      return plan
    } catch {
      setFailure(error)
      throw error
    }
  }

  public func apply(planID: UUID) async throws {
    try enter()
    defer { busy = false }
    guard let selected = preview, selected.plan.id == planID else {
      throw ApplyCoordinatorFailure.stalePlan
    }
    preview = nil
    let plan = selected.plan
    var intentSaved = false
    var commitStarted = false
    do {
      _ = try await revalidate(selected)
      try Task.checkCancellation()
      if plan.operation == .noChange {
        currentState = .unchanged
        return
      }
      currentState = .authorizing(plan.id)
      try await environment.authorize(plan.id)
      try Task.checkCancellation()
      let fresh = try await revalidate(selected)
      try Task.checkCancellation()
      try await store.beginApply(
        PendingApply(workspace: selected.workspace, plan: plan),
        expectedGeneration: fresh.generation)
      intentSaved = true
      // Cancellation before commit can safely discard the app intent. Once handed off, even
      // CancellationError must be treated as unknown until independently reconciled.
      try Task.checkCancellation()
      currentState = .committing(plan.id)
      commitStarted = true
      let receipt = try await environment.commit(plan)
      currentState = .verifying(plan.id)
      let pending = try PendingApply(workspace: selected.workspace, plan: plan)
      _ = try AppliedWorkspaceSnapshot(pending: pending, receipt: receipt)
      let actual = try await environment.readSystem()
      guard ContentDigest(actual) == receipt.afterDigest else {
        throw ApplyCoordinatorFailure.unverifiedResult
      }
      _ = try await store.resolveApply(plan.id, receipt: receipt)
      currentState = .applied(receipt)
    } catch {
      if intentSaved && (!commitStarted || (error as? ApplyCoordinatorFailure) == .notCommitted) {
        do { _ = try await store.resolveApply(plan.id, receipt: nil) } catch {
          currentState = .recoveryRequired
          await store.releaseApply(plan.id)
          throw error
        }
        setFailure(error)
      } else if commitStarted || (error as? WorkspaceStoreFailure) == .commitOutcomeUnknown {
        currentState = .recoveryRequired
      } else {
        setFailure(error)
      }
      await store.releaseApply(plan.id)
      throw error
    }
  }

  /// Read-only system reconciliation; never rewrites the system file. A missing receipt with
  /// after-bytes is insufficient proof. Clearing before-bytes also requires terminal non-commit
  /// evidence or a durable retirement bound to this intent and enforced by every worker.
  /// Unknown/external bytes keep the intent and block apply.
  public func reconcile() async throws -> SystemObservation {
    try enter()
    defer { busy = false }
    preview = nil
    lastRecoveryAssessment = nil
    do {
      let snapshot = try await writableSnapshot()
      guard !(await store.isApplyInFlight()) else { throw ApplyCoordinatorFailure.busy }
      if let pending = snapshot.pendingApply {
        currentState = .recoveryRequired
        // The lease spans all awaits and is shared by every coordinator using this store.
        // Draft edits remain allowed; another recovery or commit must not race this one.
        try await store.claimApplyRecovery(pending.transactionID)
        do {
          let result = try await reconcilePending(pending)
          await store.releaseApply(pending.transactionID)
          return result
        } catch {
          await store.releaseApply(pending.transactionID)
          throw error
        }
      }
      let system = try await environment.readSystem()
      let digest = ContentDigest(system)
      let fresh = try await writableSnapshot()
      guard fresh.generation == snapshot.generation else { throw ApplyCoordinatorFailure.stalePlan }
      currentState = .idle
      guard let applied = snapshot.applied else { return .unconfirmed }
      return digest == applied.receipt.afterDigest ? .confirmed : .externalChange
    } catch {
      let load = await store.state()
      if load.snapshot?.pendingApply != nil {
        currentState = .recoveryRequired
      } else {
        setFailure(error)
      }
      throw error
    }
  }

  /// Internal until a production adapter's durable exclusion and authorization are proven.
  /// Explicit request bound to the currently displayed transaction; no automatic retirement.
  func retireOrphan(transactionID: UUID) async throws -> SystemObservation {
    try enter()
    defer { busy = false }
    preview = nil
    lastRecoveryAssessment = nil
    let snapshot = try await writableSnapshot()
    guard let pending = snapshot.pendingApply, pending.transactionID == transactionID else {
      throw ApplyCoordinatorFailure.stalePlan
    }
    try await store.claimApplyRecovery(transactionID)
    currentState = .recoveryRequired
    do {
      // The adapter repeats all eligibility checks while excluding a live/delayed worker.
      let retirement = try await environment.retireOrphan(ApplyRetirement(pending: pending))
      try retirement.validate(pending: pending)
      let result = try await reconcilePending(pending)
      await store.releaseApply(transactionID)
      return result
    } catch {
      await store.releaseApply(transactionID)
      throw error
    }
  }

  private func reconcilePending(_ pending: PendingApply) async throws -> SystemObservation {
    var digest: ContentDigest?
    var evidence: ApplyRecoveryEvidence = .unavailable
    do {
      digest = ContentDigest(try await environment.readSystem())
      let outcome = try await environment.outcome(for: pending.transactionID)
      switch outcome {
      case .missingJournal: evidence = .missingJournal
      case .workerActive: evidence = .workerActive
      case .unknown: evidence = .unknown
      case .notCommitted: evidence = .notCommitted
      case .retired(let retirement):
        evidence = .invalidRetirement
        try retirement.validate(pending: pending)
        evidence = .retired
      case .committed(let receipt):
        evidence = .invalidReceipt
        _ = try AppliedWorkspaceSnapshot(pending: pending, receipt: receipt)
        evidence = .verifiedReceipt
      }
      // The first read may predate a worker finishing or an external replacement.
      digest = nil
      digest = ContentDigest(try await environment.readSystem())
      lastRecoveryAssessment = .init(pending: pending, digest: digest, evidence: evidence)
      try Task.checkCancellation()
      if case .committed(let receipt) = outcome, digest == pending.afterDigest {
        _ = try await store.resolveApply(pending.transactionID, receipt: receipt)
        currentState = .applied(receipt)
        return .confirmed
      }
      let abandoned: Bool
      switch outcome {
      case .notCommitted, .retired: abandoned = true
      default: abandoned = false
      }
      if abandoned, digest == pending.beforeDigest {
        _ = try await store.resolveApply(pending.transactionID, receipt: nil)
        currentState = .idle
        return .unconfirmed
      }
      return .recoveryRequired
    } catch {
      lastRecoveryAssessment = .init(pending: pending, digest: digest, evidence: evidence)
      throw error
    }
  }

  private func enter() throws {
    guard !busy else { throw ApplyCoordinatorFailure.busy }
    busy = true
  }

  private func writableSnapshot() async throws -> WorkspaceSnapshot {
    let load = await store.state()
    guard load.readOnlyReason == nil, let snapshot = load.snapshot else {
      throw WorkspaceStoreFailure.readOnly
    }
    return snapshot
  }

  private func revalidate(_ selected: (workspace: Workspace, plan: ApplyPlan)) async throws
    -> WorkspaceSnapshot
  {
    let actual = try await environment.readSystem()
    let snapshot = try await writableSnapshot()
    guard snapshot.pendingApply == nil else { throw ApplyCoordinatorFailure.recoveryRequired }
    guard try selected.plan.isCurrent(workspace: snapshot.draft, system: actual) else {
      throw ApplyCoordinatorFailure.stalePlan
    }
    return snapshot
  }

  private func setFailure(_ error: any Error) {
    if (error as? ApplyCoordinatorFailure) == .recoveryRequired {
      currentState = .recoveryRequired
    } else if error is CancellationError || (error as? ApplyCoordinatorFailure) == .cancelled {
      currentState = .cancelled
    } else {
      currentState = .failed
    }
  }
}
