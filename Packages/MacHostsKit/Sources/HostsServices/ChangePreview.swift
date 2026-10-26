import Foundation
import HostsCore

/// One ownership/planning contract for the read-only preview and committing coordinator.
enum WorkspaceApplyPlanner {
  static func prepare(snapshot: WorkspaceSnapshot, system: Data) throws -> ApplyPlan {
    try snapshot.validate()
    guard snapshot.pendingApply == nil else { throw ApplyCoordinatorFailure.recoveryRequired }
    let document = HostsDocument.parse(system, context: .system)
    let actualManaged = document.managedBlock.map { ContentDigest(system.subdata(in: $0)) }
    if let applied = snapshot.applied {
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
    return try ApplyPlan.prepare(
      workspace: snapshot.draft, system: system,
      expectedManagedDigest: snapshot.applied?.managedDigest,
      separatorEvidence: snapshot.applied?.separatorEvidence)
  }
}

/// Frozen inputs include the entire draft and saved generation, not only active source text.
/// An observation failure/restart is represented by absent contents and invalidates a preview.
public struct ChangePreviewInput: Equatable, Sendable {
  public let observationRevision: UInt64
  public let workspace: Workspace
  public let snapshot: WorkspaceSnapshot?
  public let readOnly: Bool
  public let contents: SystemFileContents?

  public init(
    workspace: Workspace, load: WorkspaceLoad, contents: SystemFileContents?,
    observationRevision: UInt64 = 0
  ) {
    self.observationRevision = observationRevision
    self.workspace = workspace
    snapshot = load.snapshot
    readOnly = load.readOnlyReason != nil
    self.contents = contents
  }
}

public enum ChangePreviewFailure: Error, Equatable, Sendable {
  case unavailable, unsavedDraft, recoveryRequired
  case plan(PlanFailure)
}

/// Pure planning on a service actor. No file access, authorization, intent or receipt creation.
public actor ChangePreviewPlanner {
  public init() {}

  public func prepare(_ input: ChangePreviewInput) throws -> ApplyPlan {
    try Task.checkCancellation()
    guard !input.readOnly, let snapshot = input.snapshot,
      let contents = input.contents, let source = contents.source,
      ContentDigest(Data(source.utf8)) == contents.digest
    else { throw ChangePreviewFailure.unavailable }
    guard snapshot.draft == input.workspace else { throw ChangePreviewFailure.unsavedDraft }
    guard snapshot.pendingApply == nil else { throw ChangePreviewFailure.recoveryRequired }
    do {
      let plan = try WorkspaceApplyPlanner.prepare(snapshot: snapshot, system: Data(source.utf8))
      try Task.checkCancellation()
      return plan
    } catch let failure as PlanFailure {
      throw ChangePreviewFailure.plan(failure)
    }
  }
}

/// Navigation belongs to a frozen draft, never to historical removed mappings.
/// Resolve again at the UI boundary to reject edits or deletion in another window.
public struct ChangePreviewLocation: Equatable, Sendable {
  public let profileID: UUID
  public let location: ProfileDiagnosticLocation

  public init?(input: ChangePreviewInput, profileID: UUID?, line: Int?) {
    guard let profileID,
      let profile = input.workspace.profiles.first(where: { $0.id == profileID }),
      let location = ProfileDiagnosticLocation(
        document: HostsDocument.parse(Data(profile.source.utf8), context: .profile), line: line)
    else { return nil }
    self.profileID = profileID
    self.location = location
  }

  init(profileID: UUID, location: ProfileDiagnosticLocation) {
    self.profileID = profileID
    self.location = location
  }

  public func range(in workspace: Workspace) -> NSRange? {
    guard let profile = workspace.profiles.first(where: { $0.id == profileID }) else { return nil }
    return location.range(in: profile.source)
  }
}

extension ChangePreviewPlanner {
  /// Only currently displayed origins are indexed; historical removals are excluded.
  /// Each requested profile is parsed once, away from the UI actor.
  public func locations(
    in input: ChangePreviewInput, plan: ApplyPlan?, failure: ChangePreviewFailure?
  ) throws -> [UUID: [Int: ChangePreviewLocation]] {
    var requested: [UUID: Set<Int>] = [:]
    func include(_ mappings: [ComposedMapping]) {
      for mapping in mappings.prefix(100) {
        for origin in mapping.origins.prefix(20) {
          if let id = origin.profileID { requested[id, default: []].insert(origin.line) }
        }
      }
    }
    if let plan { include(plan.added) }
    if case .plan(.conflicts(let conflicts)) = failure {
      for conflict in conflicts.prefix(100) { include(conflict.mappings) }
    }
    if case .plan(.invalidDocuments(let diagnostics)) = failure {
      for item in diagnostics.prefix(100) {
        if let id = item.profileID, let line = item.diagnostic.line {
          requested[id, default: []].insert(line)
        }
      }
    }
    var result: [UUID: [Int: ChangePreviewLocation]] = [:]
    for profile in input.workspace.profiles {
      try Task.checkCancellation()
      guard let lines = requested[profile.id] else { continue }
      let data = Data(profile.source.utf8)
      let document = HostsDocument.parse(data, context: .profile)
      let digest = ContentDigest(data)
      var offset = 0
      for line in document.lines {
        let length = line.content.utf16.count
        if lines.contains(line.number) {
          result[profile.id, default: [:]][line.number] = ChangePreviewLocation(
            profileID: profile.id,
            location: ProfileDiagnosticLocation(
              digest: digest, range: NSRange(location: offset, length: length)))
        }
        offset += length + line.ending.utf16.count
      }
    }
    return result
  }
}
