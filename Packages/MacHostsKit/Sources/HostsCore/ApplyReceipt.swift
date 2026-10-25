import Foundation

/// A receipt describes a file result independently of resolver-cache flushing.
/// Constructing/decoding this value is not authorization or proof of a privileged write.
public struct ApplyReceipt: Codable, Equatable, Sendable {
  public enum Readback: String, Codable, Sendable { case verified, mismatch }
  public enum CacheFlush: String, Codable, Sendable { case notAttempted, succeeded, failed }
  public let transactionID: UUID
  public let beforeDigest: ContentDigest
  public let afterDigest: ContentDigest
  public let backupID: UUID
  public let readback: Readback
  public let cacheFlush: CacheFlush

  public init(
    transactionID: UUID, beforeDigest: ContentDigest, afterDigest: ContentDigest, backupID: UUID,
    readback: Readback, cacheFlush: CacheFlush
  ) {
    self.transactionID = transactionID
    self.beforeDigest = beforeDigest
    self.afterDigest = afterDigest
    self.backupID = backupID
    self.readback = readback
    self.cacheFlush = cacheFlush
  }
}

public enum AppliedSnapshotFailure: Error, Equatable, Sendable {
  case unverifiedReceipt, planMismatch
}

public struct AppliedWorkspaceSnapshot: Codable, Equatable, Sendable {
  public let workspace: Workspace
  public let workspaceDigest: ContentDigest
  public let receipt: ApplyReceipt
  public let managedDigest: ContentDigest?
  public let separatorEvidence: ManagedSeparatorEvidence?

  public init(workspace: Workspace, plan: ApplyPlan, receipt: ApplyReceipt) throws {
    guard receipt.readback == .verified else { throw AppliedSnapshotFailure.unverifiedReceipt }
    guard ContentDigest(try workspace.encoded()) == plan.workspaceDigest,
      receipt.transactionID == plan.id, receipt.beforeDigest == plan.expectedSystemDigest,
      receipt.afterDigest == plan.resultingSystemDigest
    else { throw AppliedSnapshotFailure.planMismatch }
    self.workspace = workspace
    workspaceDigest = plan.workspaceDigest
    self.receipt = receipt
    let document = HostsDocument.parse(plan.after, context: .system)
    managedDigest = document.managedBlock.map { ContentDigest(plan.after.subdata(in: $0)) }
    separatorEvidence = plan.separatorEvidence
  }

  /// Recovery requires an independently obtained receipt and a fresh system readback at the service boundary.
  public init(pending: PendingApply, receipt: ApplyReceipt) throws {
    try pending.validate()
    guard receipt.readback == .verified else { throw AppliedSnapshotFailure.unverifiedReceipt }
    guard receipt.transactionID == pending.transactionID,
      receipt.beforeDigest == pending.beforeDigest, receipt.afterDigest == pending.afterDigest
    else { throw AppliedSnapshotFailure.planMismatch }
    workspace = pending.workspace
    workspaceDigest = pending.workspaceDigest
    self.receipt = receipt
    managedDigest = pending.managedDigest
    separatorEvidence = pending.separatorEvidence
  }

  public func validate() throws {
    guard receipt.readback == .verified else { throw AppliedSnapshotFailure.unverifiedReceipt }
    guard ContentDigest(try workspace.encoded()) == workspaceDigest,
      separatorEvidence == nil || separatorEvidence?.systemDigest == receipt.afterDigest
    else {
      throw AppliedSnapshotFailure.planMismatch
    }
  }
}
