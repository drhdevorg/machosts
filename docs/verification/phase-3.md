# Phase 3 – Workspace storage and local recovery

As of October 25, 2026. **Implemented and locally verified; gate 3 passed for initial schema 1.** Phase 2 passed locally. Formal phase-1 clean-checkout/CI evidence remains open. Gate 0/real privileged integration remain deferred.

[Phase 4](phase-4.md) subsequently extends snapshots to schema 2 with backed-up schema-1 migration. The following records the original phase-3 milestone.

## Implemented

- Actor `WorkspaceStore`, versioned `WorkspaceSnapshot`, monotonic save generation, revision-checked drafts. Stable IDs, order, folders, trash. Delete/restore preserves text; restoring never enables automatically.
- File work outside MainActor. Explicit app-data directory created/checked as a private user-owned leaf; parent must exist. Later app integration selects Application Support. Tests use UUID temporary directories only.
- Descriptor-relative access, `O_NOFOLLOW`, regular files, owner, private mode, link count, streaming size limits. Root execution rejected. Persistent `flock` excludes a second cooperating writer; the lock file is never unlinked.
- Before publication, last confirmed snapshot is backed up as `workspace.previous.json`. New bytes use an exclusive same-directory `0600` temporary file, `fsync`, renewed digest check, atomic rename, directory flush, readback. Before-rename failures confirm no new state; after-rename failures mark outcome uncertain and block saving until reopen.
- Corrupt/truncated/unsafe/oversized/unknown-schema data is never replaced with empty data. A valid predecessor is only a recovery candidate. Missing main file plus invalid backup likewise does not silently start empty.
- `recoverPrevious` requires explicit selection/current digest. Archive corrupt original as unique `workspace.recovery-UUID.json` first. Never downgrade unknown schemas. Schema 1 was the first product format, with no supported predecessor/migration at this milestone. Schema 0/future versions remain read-only; later migrations require fixtures/backups.
- Confirmed applied workspace is separate from draft, bound to plan/workspace digest and verified receipt readback. Cache-flush failure is separate and does not prevent saving a confirmed file result. This model issues no privileged proof; actual system/tool-receipt reconciliation belongs to phase 4.
- `WorkspaceAutosave` coalesces edits, retains failed drafts/error, offers `flush`. Concurrent flush calls share a save. Replaced debounce timers never cancel an already started commit. Generation detects independent store mutations; app must coordinate store/autosave.

## Actual verification

Apple Silicon, Xcode 27.1 / Swift 6.4, macOS SDK 27.0; Swift 6 concurrency checking. [Commands/cache paths](../DEVELOPMENT.md).

| Check | Result |
| --- | --- |
| Whole package | Passed: 15 Services, 12 Core, 1 writer-availability function; parameterized cases additional; `/tmp/machosts-phase3-swift-test.log` |
| Restart/roundtrip | Draft, applied snapshot, receipt, separator evidence stay separate; mode `0600` checked |
| Failure/recovery | Truncated JSON, schema 0/99, explicit recovery/original archive, wrong digest, missing main/invalid backup |
| Write/interruption | Injected ENOSPC before write/before rename/after rename and EACCES before rename; reopen reconstructs actually published old/new snapshot |
| Concurrency | Second store rejected; concurrent expected generations allow exactly one save; external changes preserved/block saves |
| File boundary | Symlink, hardlink, unsafe directory mode, oversized snapshot rejected; private target unchanged |
| Autosave | 25 drafts coalesced, concurrent flush, actual delayed timer, failed save preserves dirty state |
| Strict recursive formatting | Passed; `/tmp/machosts-phase3-format.log` |
| Incremental Release build | Passed; `/tmp/machosts-phase3-build.log`; manifest cache access outside coding sandbox required |

No warnings in our Swift code in the final run. SwiftPM warns about optional unavailable user caches. Xcode reports expected skipped AppIntents extraction without its framework dependency. Initial store build used explicit `timespec` field comparison after Equatable proved unavailable; final run passed.

## Limits and continuation

Interruption points are deterministic injected failures on actual private files, not hardware/power-loss evidence. Unconfirmed temporary files from actual process termination are never automatically applied; confirmed snapshots/predecessors remain recovery bases. A noncooperating same-user writer can intervene between last check/rename or replace the private directory; no system-wide atomic compare-and-swap is claimed.

This milestone included no system-wide recovery, recovery-selection UI, app autosave integration, or new profile UI. Preserve unknown/new schemas for compatible builds; no speculative import/downgrade. Backups retain one predecessor; explicit recovery archives are not automatically removed. Retention/export/UI follow later.

The unavailable writer is unchanged and contract-tested. No workstation hosts read/write, authorization, root process, networking, or publication. Next: phase-4 coordinator/recovery with private fixtures. Production authorization/integration still requires gate 0/postponed VM evidence.
