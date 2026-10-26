# ADR 0003 – Durably retire orphaned apply intents

Date: October 25, 2026. Status: internal contract implemented and verified on private fixtures; no approval of a privileged protocol. Gates 0 and 4 remain open.

## Problem

A saved app intent can survive process termination without a system journal. The current file digest proves neither a historical commit nor its absence. A delayed worker could also acquire its process lock only after a recovery attempt. A missing journal and currently free lock therefore do not suffice to delete the intent safely.

## Decision

An explicitly requested internal `retireOrphan` operation creates a durable retirement record for the specific transaction. `ApplyRetirement` binds version 1, transaction ID, before/after digest, and workspace digest. It contains no profile text, paths, commands, or authorization data. Retirement is neither a receipt nor proof that no historical write occurred. The outcome is explicitly named `retired`, separately from `notCommitted`.

1. The app must identify the still-open transaction and hold the shared recovery claim. Newer draft changes remain allowed. No automatic retirement through observation or normal reconciliation.
2. The system adapter must hold the same exclusive process lock as every commit. Active workers prevent retirement. Delayed workers must check retirement records after acquiring the lock, before writing backups, journals, or target bytes.
3. Retirement is allowed only without a journal for the ID, without another prepared transaction, and with freshly read before-bytes. Existing journals use the existing recovery path. After-bytes, other bytes, read errors, and corrupt evidence stay blocked.
4. The adapter durably saves and reads back retirement, synchronizes file/directory, then rechecks unchanged target identity, bytes, and metadata. An identical binding is idempotent; a different binding for the same ID is an error. Contradictory journals and retirement records block progress.
5. Every commit rejects a retired ID as `replay`, regardless of requested digests or operations. Retirement remains after resolving the app intent. Retention must not remove it without proving exclusion of all old requests.
6. Later recovery synchronizes even an already visible retirement record again. An earlier process might have died after rename but before directory sync. Failed sync permits no terminal evidence. Process-termination tests do not establish filesystem power-loss durability.
7. The app validates independent retirement evidence fully against its intent and rereads system bytes afterward. Only a before-digest match resolves the intent without a new receipt. An older applied snapshot and newer draft remain; the outcome is `unconfirmed`. Later normal reconciliation can separately compare the older receipt with the current file.

After recording retirement, read errors, cancellation, external changes, or app-save failures may prevent resolution. The intent then remains, but the durably retired transaction must never commit again. A later restart can rediscover the record independently. Even a historical commit with a lost journal and subsequently restored before-bytes creates no invented success or non-commit proof through this path.

## Scope and consequences

This extends the allowed terminal evidence. The architecture rule that matching bytes alone are insufficient remains. Retirement changes only independent transaction evidence and app data, never target bytes. It does not replace controlled restore and is no escape path for after/foreign bytes.

The coordinator method is internal. Only test adapters implement it; the default throws `integrationUnavailable`. There is no UI action or CLI switch for discarding intents. Production UI remains blocked on orphaned intents. Workspace schema 2 is unchanged.

Production use requires safe authorization, trusted storage/transport, bounded unambiguous decoding, complete metadata validation, and gate-0 provenance evidence. Every worker, including older/delayed processes, must honor retirement records; mixed protocol generations need separate evidence. App/system data must be assessed together for backup, downgrade, and cleanup. Deleting/resetting independent retirement records removes replay protection. There is still no atomic compare-and-swap against noncooperating external writers.

Results and limits: [Phase 4](../verification/phase-4.md).
