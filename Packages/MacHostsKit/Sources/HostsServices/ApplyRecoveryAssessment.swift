import Foundation
import HostsCore

/// A point-in-time comparison, never proof that a worker did or did not commit.
public enum PendingApplyFileState: Equatable, Sendable {
  case before, after, other, unreadable

  public init(pending: PendingApply, digest: ContentDigest?) {
    switch digest {
    case nil: self = .unreadable
    case pending.beforeDigest: self = .before
    case pending.afterDigest: self = .after
    default: self = .other
    }
  }
}

/// Diagnostic evidence from an independent system adapter. Missing records and live workers
/// deliberately differ from a terminal non-commit. None of these values authorize a write.
public enum ApplyRecoveryEvidence: Equatable, Sendable {
  case missingJournal, workerActive, unknown, unavailable, invalidReceipt
  case notCommitted, verifiedReceipt, retired, invalidRetirement
}

/// Last recovery attempt, with no profile contents or system bytes. A missing journal is an
/// orphaned app intent even when the current file happens to match its before/after digest.
/// Such an intent remains persisted until terminal evidence or a separately persisted retirement
/// excludes future commits. Matching bytes alone never dismiss it.
public struct ApplyRecoveryAssessment: Equatable, Sendable {
  public let transactionID: UUID
  public let fileState: PendingApplyFileState
  public let evidence: ApplyRecoveryEvidence

  init(pending: PendingApply, digest: ContentDigest?, evidence: ApplyRecoveryEvidence) {
    transactionID = pending.transactionID
    fileState = PendingApplyFileState(pending: pending, digest: digest)
    self.evidence = evidence
  }
}
