import Foundation
import HostsCore

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
  public static let currentSchema = 2
  public let schemaVersion: Int
  public let generation: UInt64
  public let draft: Workspace
  public let applied: AppliedWorkspaceSnapshot?
  public let pendingApply: PendingApply?

  public init(
    generation: UInt64 = 0, draft: Workspace = Workspace(),
    applied: AppliedWorkspaceSnapshot? = nil,
    pendingApply: PendingApply? = nil
  ) {
    schemaVersion = Self.currentSchema
    self.generation = generation
    self.draft = draft
    self.applied = applied
    self.pendingApply = pendingApply
  }

  public func validate() throws {
    guard schemaVersion == Self.currentSchema else { throw WorkspaceFailure.unsupportedSchema }
    try draft.validate()
    try applied?.validate()
    try pendingApply?.validate()
  }

  public func encoded() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(self)
    guard bytes.count <= HostsLimits.workspaceBytes else { throw WorkspaceFailure.limitExceeded }
    return bytes
  }
}

public enum WorkspaceRecoveryReason: Equatable, Sendable {
  case corruptSnapshot, unsupportedSchema, unsafeOrUnreadableFile, interruptedCommit, externalChange
  case migrationFailed
}

public struct WorkspaceLoad: Sendable {
  public let snapshot: WorkspaceSnapshot?
  public let readOnlyReason: WorkspaceRecoveryReason?
  /// A valid previous snapshot is an explicit recovery candidate, never an automatic replacement.
  public let recoveryCandidate: WorkspaceSnapshot?
}

/// Serializes local app data. It never opens the system hosts file or invokes authorization.
public actor WorkspaceStore {
  private let files: WorkspaceFiles
  private var load: WorkspaceLoad
  private var persistedBytes: Data?
  private var activeApply: UUID?

  private init(files: WorkspaceFiles, load: WorkspaceLoad, bytes: Data?) {
    self.files = files
    self.load = load
    persistedBytes = bytes
  }

  /// The parent must already exist; the leaf directory is created privately when absent.
  /// File work runs on this non-UI service boundary, not in a MainActor initializer.
  public static func open(directory: URL) async throws -> WorkspaceStore {
    try openFiles(WorkspaceFiles(directory: directory))
  }

  /// Resolves the standard local app-data location off the UI actor. The existing
  /// WorkspaceFiles boundary validates and exclusively locks the MacHosts directory.
  public static func openDefault() async throws -> WorkspaceStore {
    let parent = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    return try await open(directory: parent.appendingPathComponent("MacHosts", isDirectory: true))
  }

  static func open(directory: URL, fault: @escaping @Sendable (WorkspaceWritePoint) throws -> Void)
    async throws -> WorkspaceStore
  {
    try openFiles(WorkspaceFiles(directory: directory, fault: fault))
  }

  private struct SchemaHeader: Decodable { let schemaVersion: Int }
  private struct LegacySnapshot: Decodable {
    let schemaVersion: Int
    let generation: UInt64
    let draft: Workspace
    let applied: AppliedWorkspaceSnapshot?
  }

  private static func decode(_ data: Data) throws -> WorkspaceSnapshot {
    struct Header: Decodable { let schemaVersion: Int }
    let decoder = JSONDecoder()
    let header = try decoder.decode(Header.self, from: data)
    guard header.schemaVersion == WorkspaceSnapshot.currentSchema else {
      throw WorkspaceFailure.unsupportedSchema
    }
    let snapshot = try decoder.decode(WorkspaceSnapshot.self, from: data)
    try snapshot.validate()
    return snapshot
  }

  private static func openFiles(_ files: WorkspaceFiles) throws -> WorkspaceStore {
    var previous: WorkspaceSnapshot?
    var previousExists = false
    do {
      if let data = try files.read("workspace.previous.json") {
        previousExists = true
        previous = try decode(data)
      }
    } catch {
      // A broken backup never replaces or invalidates an otherwise valid current snapshot.
      previousExists = true
      previous = nil
    }
    let bytes: Data?
    do { bytes = try files.read("workspace.json") } catch {
      return WorkspaceStore(
        files: files,
        load: .init(
          snapshot: nil, readOnlyReason: .unsafeOrUnreadableFile, recoveryCandidate: previous),
        bytes: nil)
    }
    guard let bytes else {
      // A missing current file alongside an existing backup is a recovery state, not a new workspace.
      if previousExists {
        return WorkspaceStore(
          files: files,
          load: .init(snapshot: nil, readOnlyReason: .corruptSnapshot, recoveryCandidate: previous),
          bytes: nil)
      }
      return WorkspaceStore(
        files: files,
        load: .init(snapshot: WorkspaceSnapshot(), readOnlyReason: nil, recoveryCandidate: nil),
        bytes: nil)
    }
    var migrating = false
    do {
      let header = try JSONDecoder().decode(SchemaHeader.self, from: bytes)
      let snapshot: WorkspaceSnapshot
      if header.schemaVersion == 1 {
        let legacy = try JSONDecoder().decode(LegacySnapshot.self, from: bytes)
        guard legacy.generation < UInt64.max else { throw WorkspaceStoreFailure.generationOverflow }
        snapshot = WorkspaceSnapshot(
          generation: legacy.generation + 1, draft: legacy.draft, applied: legacy.applied)
        let migrated = try snapshot.encoded()
        // Archive the exact old schema before publishing. A failed migration never starts empty.
        migrating = true
        try files.recoverSnapshot(migrated, preserving: bytes)
        return WorkspaceStore(
          files: files,
          load: .init(snapshot: snapshot, readOnlyReason: nil, recoveryCandidate: nil),
          bytes: migrated)
      }
      snapshot = try decode(bytes)
      return WorkspaceStore(
        files: files,
        load: .init(snapshot: snapshot, readOnlyReason: nil, recoveryCandidate: previous),
        bytes: bytes)
    } catch {
      let reason: WorkspaceRecoveryReason
      if (error as? WorkspaceStoreFailure) == .commitOutcomeUnknown {
        reason = .interruptedCommit
      } else if migrating {
        reason = .migrationFailed
      } else {
        reason =
          (error as? WorkspaceFailure) == .unsupportedSchema ? .unsupportedSchema : .corruptSnapshot
      }
      return WorkspaceStore(
        files: files,
        load: .init(snapshot: nil, readOnlyReason: reason, recoveryCandidate: previous),
        bytes: bytes)
    }
  }

  public func state() -> WorkspaceLoad { load }

  public func saveDraft(_ draft: Workspace, expectedGeneration: UInt64) throws -> WorkspaceSnapshot
  {
    let current = try writable(expectedGeneration)
    try draft.validate()
    if draft == current.draft {
      do { try files.checkCurrent(persistedBytes.map(ContentDigest.init)) } catch {
        if (error as? WorkspaceStoreFailure) == .externalChange {
          load = .init(
            snapshot: current, readOnlyReason: .externalChange,
            recoveryCandidate: load.recoveryCandidate)
        }
        throw error
      }
      return current
    }
    guard draft.revision > current.draft.revision else { throw WorkspaceStoreFailure.staleRevision }
    let next = WorkspaceSnapshot(
      generation: try nextGeneration(current), draft: draft, applied: current.applied,
      pendingApply: current.pendingApply)
    return try commit(next)
  }

  /// Caller supplies a receipt-bound applied snapshot; newer draft edits remain untouched.
  public func recordApplied(_ applied: AppliedWorkspaceSnapshot, expectedGeneration: UInt64) throws
    -> WorkspaceSnapshot
  {
    let current = try writable(expectedGeneration)
    try applied.validate()
    guard current.pendingApply == nil else { throw ApplyCoordinatorFailure.recoveryRequired }
    let next = WorkspaceSnapshot(
      generation: try nextGeneration(current), draft: current.draft, applied: applied)
    return try commit(next)
  }

  func beginApply(_ pending: PendingApply, expectedGeneration: UInt64) throws {
    let current = try writable(expectedGeneration)
    guard current.pendingApply == nil else { throw ApplyCoordinatorFailure.recoveryRequired }
    guard current.draft == pending.workspace else { throw ApplyCoordinatorFailure.stalePlan }
    try pending.validate()
    _ = try commit(
      WorkspaceSnapshot(
        generation: try nextGeneration(current), draft: current.draft, applied: current.applied,
        pendingApply: pending))
    activeApply = pending.transactionID
  }

  /// Atomic on this actor: preserve edits made during commit and clear only the matching intent.
  func resolveApply(_ id: UUID, receipt: ApplyReceipt?) throws -> WorkspaceSnapshot {
    guard let generation = load.snapshot?.generation else { throw WorkspaceStoreFailure.notLoaded }
    let current = try writable(generation)
    guard let pending = current.pendingApply, pending.transactionID == id else {
      throw ApplyCoordinatorFailure.recoveryRequired
    }
    let applied = try receipt.map { try AppliedWorkspaceSnapshot(pending: pending, receipt: $0) }
    let result = try commit(
      WorkspaceSnapshot(
        generation: try nextGeneration(current), draft: current.draft,
        applied: applied ?? current.applied))
    activeApply = nil
    return result
  }

  func isApplyInFlight() -> Bool { activeApply != nil }

  /// Serializes recovery across separate coordinators, including their suspension points.
  /// No bytes are changed until independently checked evidence reaches resolveApply.
  func claimApplyRecovery(_ id: UUID) throws {
    guard activeApply == nil else { throw ApplyCoordinatorFailure.busy }
    guard let generation = load.snapshot?.generation else { throw WorkspaceStoreFailure.notLoaded }
    let current = try writable(generation)
    guard current.pendingApply?.transactionID == id else {
      throw ApplyCoordinatorFailure.recoveryRequired
    }
    activeApply = id
  }

  func releaseApply(_ id: UUID) {
    if activeApply == id { activeApply = nil }
  }

  public func currentFileDigest() -> ContentDigest? { persistedBytes.map(ContentDigest.init) }

  /// Explicit app-data recovery only. Unknown schemas are never downgraded. Preserve the
  /// corrupt original under a unique recovery name before publishing the validated candidate.
  public func recoverPrevious(expectedCurrentDigest: ContentDigest?) throws -> WorkspaceSnapshot {
    guard load.readOnlyReason == .corruptSnapshot, let candidate = load.recoveryCandidate else {
      throw WorkspaceStoreFailure.readOnly
    }
    guard expectedCurrentDigest == persistedBytes.map(ContentDigest.init) else {
      throw WorkspaceStoreFailure.externalChange
    }
    let next = WorkspaceSnapshot(
      generation: try nextGeneration(candidate), draft: candidate.draft, applied: candidate.applied,
      pendingApply: candidate.pendingApply)
    let data = try next.encoded()
    do { try files.recoverSnapshot(data, preserving: persistedBytes) } catch {
      if (error as? WorkspaceStoreFailure) == .commitOutcomeUnknown {
        load = .init(
          snapshot: nil, readOnlyReason: .interruptedCommit, recoveryCandidate: candidate)
      }
      throw error
    }
    persistedBytes = data
    load = .init(snapshot: next, readOnlyReason: nil, recoveryCandidate: candidate)
    return next
  }

  private func writable(_ expectedGeneration: UInt64) throws -> WorkspaceSnapshot {
    guard load.readOnlyReason == nil else { throw WorkspaceStoreFailure.readOnly }
    guard let current = load.snapshot else { throw WorkspaceStoreFailure.notLoaded }
    guard current.generation == expectedGeneration else {
      throw WorkspaceStoreFailure.staleGeneration
    }
    return current
  }

  private func nextGeneration(_ current: WorkspaceSnapshot) throws -> UInt64 {
    guard current.generation < UInt64.max else { throw WorkspaceStoreFailure.generationOverflow }
    return current.generation + 1
  }

  private func commit(_ next: WorkspaceSnapshot) throws -> WorkspaceSnapshot {
    let data = try next.encoded()
    do { try files.writeSnapshot(data, previous: persistedBytes) } catch {
      if (error as? WorkspaceStoreFailure) == .commitOutcomeUnknown
        || (error as? WorkspaceStoreFailure) == .externalChange
      {
        load = .init(
          snapshot: load.snapshot,
          readOnlyReason: (error as? WorkspaceStoreFailure) == .externalChange
            ? .externalChange : .interruptedCommit,
          recoveryCandidate: load.recoveryCandidate)
      }
      throw error
    }
    load = .init(snapshot: next, readOnlyReason: nil, recoveryCandidate: load.snapshot)
    persistedBytes = data
    return next
  }
}
