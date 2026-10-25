import Foundation

/// Durable exclusion of future commits for one abandoned transaction, not proof of its history.
/// This value is an internal adapter contract, never an authorization token or a write receipt.
public struct ApplyRetirement: Codable, Equatable, Sendable {
  public let version: Int
  public let transactionID: UUID
  public let beforeDigest: ContentDigest
  public let afterDigest: ContentDigest
  public let workspaceDigest: ContentDigest

  public init(pending: PendingApply) throws {
    try pending.validate()
    version = 1
    transactionID = pending.transactionID
    beforeDigest = pending.beforeDigest
    afterDigest = pending.afterDigest
    workspaceDigest = pending.workspaceDigest
  }

  public func validate() throws {
    guard version == 1, beforeDigest != afterDigest else {
      throw AppliedSnapshotFailure.planMismatch
    }
  }

  public func validate(pending: PendingApply) throws {
    guard self == (try ApplyRetirement(pending: pending)) else {
      throw AppliedSnapshotFailure.planMismatch
    }
  }
}
