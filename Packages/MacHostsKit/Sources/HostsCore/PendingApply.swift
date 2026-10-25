import Foundation

/// App-side intent, durably stored before handing control to a committing adapter.
/// This is not a tool journal or evidence that a system write occurred.
public struct PendingApply: Codable, Equatable, Sendable {
  public let transactionID: UUID
  public let workspace: Workspace
  public let workspaceDigest: ContentDigest
  public let beforeDigest: ContentDigest
  public let afterDigest: ContentDigest
  public let managedDigest: ContentDigest?
  public let separatorEvidence: ManagedSeparatorEvidence?

  public init(workspace: Workspace, plan: ApplyPlan) throws {
    guard ContentDigest(try workspace.encoded()) == plan.workspaceDigest,
      plan.operation != .noChange
    else { throw AppliedSnapshotFailure.planMismatch }
    transactionID = plan.id
    self.workspace = workspace
    workspaceDigest = plan.workspaceDigest
    beforeDigest = plan.expectedSystemDigest
    afterDigest = plan.resultingSystemDigest
    let document = HostsDocument.parse(plan.after, context: .system)
    managedDigest = document.managedBlock.map { ContentDigest(plan.after.subdata(in: $0)) }
    separatorEvidence = plan.separatorEvidence
  }

  public func validate() throws {
    guard ContentDigest(try workspace.encoded()) == workspaceDigest, beforeDigest != afterDigest,
      separatorEvidence == nil || separatorEvidence?.systemDigest == afterDigest
    else { throw AppliedSnapshotFailure.planMismatch }
  }
}
