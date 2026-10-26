# Phase 4 – Apply, app recovery, private file transactions (partial completion)

As of October 25, 2026. **Coordinator, persistent app recovery, internal transactions, end-to-end private integration, and actual process restarts verified locally. Gate 4 remains open.** [ADR 0002](../decisions/0002-deferred-gate-0.md) defers gate 0. Phases 2/3 passed locally; formal phase-1 clean-checkout/CI evidence remains open.

The sections record successive milestones. Initial “not yet integrated” statements describe their date within that sequence; later sections supersede them. Git was absent during these runs and added later. Current UI/editor/build status is in [phase 5](phase-5.md).

## Initial implementation

- `ApplyCoordinator` serializes preparation, preview, authorization, commit, verification with an explicit claim across `await`. Preparation uses only the saved draft; workspace digest/revision/fresh system bytes are rechecked before commit. UI must flush its editor/autosave first; the service cannot see unsaved edits.
- Immutable `ApplyPlan` preview. Duplicate clicks/parallel prepare rejected. No-op requires no authorization/journal and issues no new receipt. Applied snapshot remains separate from desired state.
- Last confirmed block digest prevents silent overwrite of externally modified/removed owned blocks. Foreign-only changes may enter a new preview. An existing MacHosts block is not adopted without confirmed applied state. Older receipts without block digest use conservative whole-file checks. Separator ownership needs existing exact digest evidence.
- `PendingApply` binds transaction ID, frozen workspace/workspace digest, before/after digest, block digest, separator evidence. App persists it **before** commit; it is no privileged journal/backup/write proof. Failed intent save never starts commit.
- Schema 2 contains pending intent. Validated schema 1 migrates atomically only after exact original-byte archive as unique `workspace.recovery-UUID.json`. Generation increases once, draft/receipt survive. Migration failure becomes read-only; after-rename failure reopens rather than inventing an outcome. Unknown schemas never downgrade; older builds reject schema 2.
- Cancellation before commit preserves applied state. Timeout/cancellation/bad receipt/contradictory readback/app-save failure after commit starts produce `recoveryRequired`. Intent clears only on proven non-start or confirmed completion. Cache-flush failure remains separate, never rolls back verified file success.
- Restart reads actual bytes and demands independent terminal adapter evidence. Valid receipt plus after-digest reconstructs applied snapshot. Before-digest needs authoritative terminal non-commit proof; no receipt alone cannot exclude a delayed writer. Missing/contradictory evidence/foreign bytes stay blocked. No automatic system write/full restore.
- Store preserves newer drafts during commit and resolves only matching transaction ID. Store runtime claim blocks another coordinator's recovery during commit; process lock excludes a second workspace writer. Autosave tolerates intent/receipt generations only while its old draft is unchanged; foreign drafts are not overwritten.
- Internal adapter exists only in tests. Public coordinator's unavailable adapter fails preparation with `integrationUnavailable`. App/writer/CLI perform no authorization or success simulation and expose no arbitrary target mode.

## Initial actual verification

Apple Silicon, Xcode 27.1 / Swift 6.4, SDK 27.0. [Commands/cache paths](../DEVELOPMENT.md). No network request.

| Check | Result |
| --- | --- |
| Whole package | Passed: 29 Services, 12 Core, 1 writer-availability function; parameterized cases additional; `/tmp/machosts-phase4-swift-test.log` |
| Normal/no-op/disable | Confirmed state; no authorization/new receipt on no-op; exact removal with separator evidence; external change detection |
| Suspension/concurrency | Double click/prepare during authorization, workspace/system edits during approval, second coordinator during commit, newer drafts/autosave across intent generations |
| Cancellation/failure | User/task cancellation before commit, cancellation after commit with confirmed actual outcome, proven non-commit, separate flush failure, invalid receipt/contradictory readback |
| Restart | Intent before/after simulated commit, missing terminal evidence with before/after bytes, app-save failures before/after rename, reopen/receipt reconciliation |
| Migration | Schema-1 fixture with applied state/old receipt, exact original archive, before/after-rename failure, no empty replacement/double migration |
| Strict recursive formatting | Passed; `/tmp/machosts-phase4-format.log` |
| Incremental Release build | Passed; `/tmp/machosts-phase4-build.log`; manifest-cache access outside coding sandbox |

Initial coordinator tests keep system bytes in memory and explicitly inject authorization/commit/terminal results. Only snapshots/migration/app-save failures use actual private files. This first milestone did not test system-file backup/metadata/rename/readback. Existing Core cases cover parser/conflict/foreign bytes. No app/UI rerun because no UI change.

## Follow-up – Internal transaction contract and private files

- `ApplyPlan.replacingManagedBlock` is the shared pure planning/revalidation operation: one complete owned canonical-LF block or removal only. Foreign prefix/suffix always come from fresh target bytes. Revalidate markers/encoding/foreign conflicts/result limits. Request adapter normalizes only generated block; original end-marker terminator/foreign bytes survive.
- `SystemTransactionRequest` is an internal **in-process contract**, not privileged JSON/IPC. Version, ID, before/after digest, prior block digest, typed mutation; no paths, shell, workspace data, foreign replacement bytes. No authorization/ownership proof for an existing foreign block; prior confirmation remains required.
- `FileTransaction` needs an exclusive synchronous adapter. Check all saved journals/backups before write; replay/open transactions block. No-op produces no backup/journal/receipt. Independently save/read back original bytes/supported metadata before prepared journal; then identity/revision check, rename, readback, terminal receipt. Cache flush stays `notAttempted`.
- `PrivateTransactionFiles` exists only in test target, creates its own temporary directory, no selectable target. Executes descriptor-relative access, `O_NOFOLLOW`, regular single-link user-owned `0600` files, bounded reads, mtime/ctime, `flock`, exclusive temp files, `fsync`, `renameat`. Rejects symlink/hardlink/FIFO/directory/open mode/flags/ACL/foreign xattrs. Automatic `com.apple.provenance` is bounded, backed up, byte-compared during replacement; mismatch stops it. No general metadata migration.
- Restart rereads journals/backups and compares bytes/metadata. Before-bytes close prepared transactions as non-commit; after-bytes are resynchronized/reread before reconstructed receipt. Missing/foreign/contradictory evidence remains blocked/unknown. Recovery never restores backup bytes automatically. Historical terminal journals retain separator proof after an interrupted later transaction.

### Actual checks

Same toolchain/commands; all writes in new private fixtures. Two accidentally concurrent coding chats were coordinated with user authorization; only one implementation is active, abandoned variants retained separately under `/tmp`.

| Check | Result |
| --- | --- |
| Whole package | Passed: 14 System, 29 Services, 12 Core functions; parameterized cases additional; `/tmp/machosts-phase4-transactions-test.log` |
| Transactions | Backup/readback, no-op, replay, apply/disable, exact foreign bytes, separator ownership after interrupted later transaction |
| Interruptions | Injected backup, pre-journal-publication, pre/post-target-rename, readback, pre-receipt-publication failures; reopen persisted files |
| Revision/integrity | Foreign bytes before rename, same bytes/new identity, corrupt backup, wrong receipt, external post-commit edit, open journal blocks new request |
| Request/format | Unknown version, stale digest, nonisolated/invalid/oversized block, disabled profile syntax, conflicts, unconfirmed block, bad markers/encoding; LF/CRLF/CR/missing final terminator |
| Private file boundary | Symlink/hardlink/FIFO/directory/unsafe modes/extra xattr/actual ACL/second lock session rejected |
| Strict recursive formatting | Passed; `/tmp/machosts-phase4-transactions-format.log` |
| Final incremental Release | Passed; `/tmp/machosts-phase4-transactions-build.log`; manifest-cache access outside sandbox |

Initial failures came from parallel files, Swift type conversions, and overstrict automatic provenance-xattr handling; corrected before final success. Interruptions here were thrown errors under exclusive lock with files reopened, not process termination/power loss/kernel/disk durability/privileged restart. Second-descriptor lock checking preceded the independent-process extension below. No UI rerun; unchanged UI.

## Follow-up – End-to-end files and actual process restarts

`CoordinatorFileIntegrationTests.swift` connects real coordinator/store via a test-only actor to `FileTransaction`/`PrivateTransactionFiles`. App/CLI/production stay blocked. Fixture can reopen its own directory with renewed directory/file/lock checks; no product test mode/selectable destination.

Normal flow: Apply → confirmed snapshot → no-op without reauthorization → Disable restoring exact foreign bytes including missing final terminator. Original backup is independently read through file adapter.

For every boundary, a child test process calls `_exit(86)` without Swift deinitialization. Parent demands exit 86, persisted pending intent, no applied snapshot. A **further new process** reopens workspace/files and runs real reconciliation:

| Termination boundary | Evidence/restart outcome |
| --- | --- |
| Commit entry after saved intent | No system journal; `recoveryRequired` |
| Before backup publication | No system journal; `recoveryRequired` |
| Before prepared journal, after persisted/read-back backup | Backup alone insufficient; `recoveryRequired` |
| Before target rename, after durable prepared journal | Before-bytes/exclusive journal reconciliation establish terminal non-commit; intent resolved |
| Immediately after rename, before directory sync | After-bytes synchronized/read; receipt reconstructed; snapshot confirmed |
| After rename/directory sync, before readback | After-bytes/journal confirm on restart |
| Before terminal receipt publication | Readback/journal permit reconstruction |
| After receipt, before return/app save | Persisted receipt confirms snapshot |

Confirmed cases reconcile again then explicitly disable, preserving original foreign bytes. Unknown cases retain intent/block preview. Missing journal plus before-bytes is never invented non-commit proof. Narrow orphan resolution remained open at this milestone; ADR 0003 later adds the internal contract.

Additional new processes check foreign target bytes and decodable but digest-invalid backup after post-rename termination. Coordinator remains blocked without target/snapshot changes. Independent child is rejected by both transaction/workspace locks.

### Actual checks

- Whole package passed: **19 System, 29 Services, 12 Core functions**, parameterized cases additional; `/tmp/machosts-phase4-process-test.log`. Five new functions include worker entry inactive during normal run. **21 children**: eight termination/recovery pairs, two external/corrupt pairs, one lock session.
- Strict recursive formatting including UI tests passed; `/tmp/machosts-phase4-process-format.log`.
- Test/docs only; package incrementally built, no app/UI rebuild.
- Initial failures: revision-0 test draft/runner management. Worker now starts current `swiftpm-testing-helper` directly with current test bundle, avoiding recursive SwiftPM locked build directory. Async child observation replaces hanging `waitUntilExit`; deadlines/cleanup included. Focused repair/full package passed.

Requires documented SwiftPM runner; other runners unverified. `_exit` proves process loss/lock release, not power loss, SIGKILL during syscall, kernel crash, disk durability. App/file engine shared one worker at this stage; next section separates them. No privileged tool evidence.

## Follow-up – App snapshot termination and independent worker lifetime

`ProcessLifecycleTests.swift` reuses disk adapter/runner. Production boundary unchanged; all targets private. Test-only transport contains initial block mutation/digests/ID; neither approved IPC nor privileged input.

### App publication matrix

Nine actual app/recovery processes end with `_exit(86)` at `WorkspaceFiles` failure points. A further process checks reconciliation, retained draft, pending intent, applied snapshot, unchanged target:

| App save | Before temp content / before rename | After rename, before directory fsync |
| --- | --- | --- |
| Intent before commit | Old draft/no intent valid; no target change; unconfirmed | Intent exists/no system journal; recovery required |
| Confirmed commit | Intent remains; terminal receipt reconstructs applied snapshot | Snapshot already present; repeat confirms |
| Reconstructed restart commit | New process can associate receipt/finish app save | Reconstruction published; idempotent repeat |

Exact pending/snapshot state checked **before** recovery. Unknown cases blocked; terminal cases repeat safely. Post-rename process death is no power-loss proof.

### Separate app and worker processes

Four cases combine worker pause before/after target rename with normal completion/`SIGKILL`. App launches independent worker holding only transaction lock, paused after durable prepared journal. App saves newer draft then `_exit(86)`; worker survives. New app/recovery can open released workspace while worker lock remains occupied.

Adapter returns unknown while lock held. Recovery blocks with both before/visible after-bytes, changes neither snapshot nor target, disallows preview. Only after completion/kill and actual lock release does another process recover:

- Normal completion confirms independent receipt.
- Pre-rename `SIGKILL` yields non-commit under exclusive journal reconciliation.
- Post-rename `SIGKILL` permits synchronized readback/receipt reconstruction.
- Newer saved draft survives; applied state uses frozen older workspace/correct ID; next preview uses new revision.

Pauses/runtime/lock waits bounded; errors clean up workers, unexpected recovery errors output logs. Normal tests enter no worker action without environment assignment.

### Actual checks

- Whole package passed: **22 System, 29 Services, 12 Core functions**, parameterized additional; `/tmp/machosts-phase4-lifecycle-test.log`. Three new functions cover nine publication failures/four lifecycles. Combined suite starts **58 child/successor processes**, four independently surviving workers.
- Formatting app/UI/tests passed; `/tmp/machosts-phase4-lifecycle-format.log`.
- Initial six-save/four-worker full run passed; final run after three recovery-save cases/shared adapter also passed. No product runtime correction required.
- Test/docs only; incremental package build, no app/UI/privileged rerun.

Evidence covers real unprivileged process loss/lifecycles/private contracts, not tool provenance, authorization, production IPC, power loss, VM integration. Gate 4 open.

## Follow-up – Unprivileged file observation

`SystemFileMonitor` provides read-only event-driven `AsyncStream`; public constructor fixes `/private/etc/hosts`, internal constructor uses private fixtures. At this initial service milestone the app did not start it; next section adds integration. Apply adapter/CLI/writer remain unavailable.

- Parent Dispatch source detects repeated atomic replacement/delete/recreate. Current-inode source adds in-place changes, reattached before every read. Debounce; identical digests suppress same-byte replacement/unrelated-directory echoes. No polling timer.
- Service-actor I/O outside MainActor. Descriptor-relative `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`, regular single-link files, streamed 4 MiB limit, after-read identity/length/mtime/ctime checks. Initially emits digest/typed error only; no content/path logs or writes. Phase 5 later adds digest-bound display contents.
- Lost/renamed/revoked parent gives `watchUnavailable`, never falsely restored merely by successful path lookup; explicit `start()` re-registers. `refresh()` supports wake/confirmed apply.
- Newest-only buffering; stop/replacement/generation-bound termination end old observation. Dispatch closes descriptors after source cancellation. Mutex protects source lifetime without blanket Sendable exceptions.
- Status compares readable digest with independent receipt. No receipt/read failure cannot confirm; mismatch is `externalChange`. Pending intent always `recoveryRequired`, even matching bytes. No receipt creation/intent resolution. UI must show errors/recompute on receipt changes.

### Actual checks

Same [toolchain/cache paths](../DEVELOPMENT.md), private files only.

| Check | Result |
| --- | --- |
| Six new contracts | Replacement/equal bytes/unrelated events/delete/recreate/in-place edits/20-change debounce/links/oversize/recovery/lost-directory restart/subscription replacement/stop/conservative receipt-intent comparison passed |
| Whole package | **22 System, 35 Services, 12 Core functions passed**; parameterized additional; `/tmp/machosts-monitor-test.log` |
| Strict formatting app/UI included | Passed; `/tmp/machosts-monitor-format.log` |
| Incremental Release | Passed; `/tmp/machosts-monitor-build.log`; user manifest-cache access outside sandbox |

Initial POSIX timestamp equality unavailable; now compares seconds/nanoseconds. First run showed directory-only observation missed in-place writes; added inode watch. Focused/full run passed. Initial sandbox Xcode cache failure/approved retry passed. No UI/sleep/wake/OS-permission matrix/real hosts monitoring. Workstation hosts neither read nor changed. Service alone is not app integration/gate-4 evidence.

## Follow-up – App observation integration

Native UI now uses MainActor/Observable `SystemObservationModel`, holding read status/workspace comparisons only. No receipts, writes, intent resolution. German/English catalog.

- Shared app-wide `AppModel` observation for all windows. `WorkspaceStore.openDefault()` outside UI actor retains process lock for app lifetime. Existing schema/recovery contracts. Visible startup failure; Check Again retries without empty replacement.
- Compare digests with saved receipt; receipt/workspace changes recompute without file events. Missing/unavailable/read-only workspace or read errors cannot confirm. Pending intent always takes precedence, including stopped observation.
- Concrete read errors/external/unconfirmed status. Check Again reads; Restart Observation replaces subscription/lost-directory watch. `NSWorkspace.didWakeNotification` triggers reread. No polling/authorization.
- Async consumption, generations protect replaced continuations, cancellation ends subscription/removes live confirmation. Closing one window does not stop app-wide task. Native lifecycle acceptance open.

### Actual checks

| Check | Result |
| --- | --- |
| Whole package after implementation | **22 System, 38 Services, 12 Core functions passed**; parameterized additional; `/tmp/machosts-observation-app-test.log` |
| Final four model contracts | Passed after persistent-intent and startup/restart additions; `/tmp/machosts-observation-app-focused.log` |
| Strict formatting app/UI included | Passed; `/tmp/machosts-observation-app-format.log` |
| Final incremental Release | Passed; `/tmp/machosts-observation-app-build.log` |

Four tests cover receipt changes without events, unavailable/read-only workspace, external changes/delete/recreate/errors, recovery precedence, startup failure/retry, lost watch, replaced subscription, cancellation. Real private workspace holds persisted intent; observations preserve snapshot/bytes. Fourth added function ran focused; unchanged full suite not repeated.

Initial sandbox manifest-cache failure, approved/final workspace-retry builds passed. No app launch/UI/real hosts/multiwindow/sleep/wake/VM tests. Standard workspace not opened; all writes private. Hosts unchanged/unread. Gate 4/full phase-5 app remain open.

## Follow-up – Orphaned intents and shared recovery claim

Internal engine returns `missingJournal`, distinct from `unknown`/proven `notCommitted`; coordinator also distinguishes `workerActive`. Empty journals/matching bytes cannot delete intent/invent receipt. Lost journal after actual fixture commit is treated as conservatively as pre-journal termination.

- `ApplyRecoveryAssessment` is transient diagnosis: transaction ID, file comparison, independent evidence kind; no content/new schema. Missing evidence/active worker/unknown/unavailable/invalid receipt differ. Receipt validates against intent even if actual bytes differ; resolution needs valid receipt **and** fresh after-digest. Proven non-commit needs fresh before-bytes. Read error/cancellation retains intent.
- `WorkspaceStore.claimApplyRecovery` serializes the whole recovery interval across coordinators. Prior active-apply check alone admitted two recoveries. Claim covers all awaits, releases after success/error/cancellation; newer drafts remain saveable/preserved. Workspace/worker process locks still necessary.
- `pendingFileState` compares without resolution. UI shows before/after/other/unreadable and unavailable transaction checks. Stopped monitor cannot claim current comparison. Production adapter cannot assert an actual missing journal.
- Orphans retained/new applies blocked, no “discard anyway” or retry write. Persistent replay-safe exclusion of delayed workers was open here; ADR 0003 below supplies internal evidence, not production approval.

### Actual checks

| Check | Result |
| --- | --- |
| Whole package | **23 System, 43 Services, 12 Core functions passed**; parameterized additional; `/tmp/machosts-orphan-test.log` |
| Later additions | **Two Services functions passed**: reopen older receipt/newer draft across three file states, unavailable production adapter with intent; `/tmp/machosts-orphan-focused.log` |
| Strict formatting | Passed, rechecked after additions; `/tmp/machosts-orphan-format.log` |
| Incremental Release | Passed; `/tmp/machosts-orphan-build-approved.log` |

Seven evidence types × three file states (**21 cases**), first/final-read failures, concurrent coordinators, system/draft edits during await, cancellation/successful retry. System cases lose journal after real private commit with before/after bytes and unchanged metadata/artifacts. Existing crash processes explicitly check missing journal/active worker. Observation covers four comparisons/preserves workspace bytes.

Initial sandbox cache failure/approved build passed. Later tests focused; no unchanged full suite/app rebuild for test/docs-only additions. No own-code warning; skipped AppIntents step. No app/UI/wake/VM/authorization; standard workspace/hosts/metadata untouched. Gates 0/4/native acceptance open.

## Follow-up – Durable retirement of journal-less intents

[ADR 0003](../decisions/0003-orphan-retirement.md) defines explicit internal retirement. Under commit's process lock, save `ApplyRetirement` bound to version/ID/before-after/workspace digests. Every later same-ID commit fails replay before backup/journal/write, even altered request. Active worker blocks retirement. Records survive app resolution.

Retirement is **neither historical non-commit proof nor receipt**. A historical commit/lost journal/restored before-bytes has its own test. Existing journals/other prepared transactions/after-foreign bytes/corrupt evidence/read failures block. Identical binding is idempotent; conflicting binding/journal blocks. Target bytes/metadata unchanged.

App holds shared claim through retirement/independent reconciliation. Fully matching evidence plus freshly read before-digest resolves intent, preserves older applied/newer draft, returns `unconfirmed`, no new receipt. After/foreign bytes/cancellation/errors retain intent; durable record may already exist and still prevents delayed commit. Recovery resynchronizes visible retirement/file directory before terminal evidence to cover post-rename/pre-directory-sync death.

Only private adapters implement it; internal coordinator method/default `integrationUnavailable`. No new UI/CLI/production adapter/schema. Earlier production block remains. Internal protocol question is addressed, privileged transport/durability still open.

### Actual checks

| Check | Result |
| --- | --- |
| Whole package | **29 System, 48 Services, 12 Core functions passed**; parameterized additional; `/tmp/machosts-retirement-test.log` |
| System suite after recovery-persistence addition | **30 System functions passed**, existing process cases/seven retirement interruptions; `/tmp/machosts-retirement-system-final.log` |
| Altered replay request addition | Two parameterized cases in existing retirement/replay function passed; `/tmp/machosts-retirement-replay-final.log` |
| Strict formatting app/UI included | Passed; `/tmp/machosts-retirement-format.log` |
| Incremental Release | Passed; `/tmp/machosts-retirement-build-approved.log` |

New processes die before record, before/after record rename, after persistence, before app write, before/after app rename. Separate recovery resolves; further independent processes reject original delayed requests. Existing independent-worker matrix rejects retirement while worker holds lock before/after rename; held lock is never terminal evidence.

Other cases: never-started/historically committed transactions, idempotence, new independent transactions, mutation during retirement, failure before/after persistence, refused durability completion, corrupt/newer/misnamed records, binding/journal conflicts. Services matrix now **nine evidence kinds × three states (27 cases)**, older receipts/newer drafts, wrong transaction ID, coordinators, draft edits during retirement, subsequent target bytes, read failure/cancellation/unavailable adapter. Claim releases on error.

Initial negative test wrongly formed an intent from a no-op; now explicit request tests blocked boundary. Full run passed. Final review added independent durability sync; affected full System suite passed. Altered replay request then focused; unchanged full suite/app build not repeated for test/comment/docs-only additions.

First sandbox Xcode call `/tmp/machosts-retirement-build.log` failed manifest cache; approved retry passed. No own Swift warnings; skipped AppIntents step. No app/UI/wake/VM/authorization/power-loss tests; standard workspace/hosts/metadata unread/unchanged. Gates 0/4 open.

## Remaining phase-4 work and limits

- Production narrow request protocol, secure privileged transport/tool provenance still require gate 0. No production authorization adapter/functional writer.
- Internal engine/private adapter do not replace protected root-owned storage, trusted system directories, complete metadata contract, strict bounded unambiguous wire/journal schemas, retention, or privileged interruption matrix. Fixture journals are not approved as untrusted privileged JSON. No production decoder/retention; bounded test journals/backups retained. Private coordinator/process/save/lifecycle/observation evidence is real, but native UI/wake acceptance remains open. Orphan production diagnosis blocks; ADR-0003 internal retirement does not prove production authorization/transport/independent persistence. Missing evidence must never pretend non-commit. Experiment code was not blindly promoted.
- No real privileged-tool recovery, multiuser proof, DNS cache/resolver integration, native observation/wake acceptance, or VM matrix. Gate 4 remains open.
- App/system remain separate transactions. Restart must reopen/reconcile before apply. “Applied” is historical confirmation; current external mismatch needs a fresh read. Foreign writers can mutate after readback; no universal atomic compare-and-swap.
- App JSON archives/predecessors are not independent system journal/receipt storage. Older builds do not support schema 2; no automatic downgrade.

During these phase-4 runs hosts bytes/permissions/metadata were neither read nor changed. No root, authorization, VM tests, publication. At that time Git was absent, so sources/tests were reviewed directly rather than by Git diff/clean checkout. Later repository initialization does not retroactively establish clean-checkout evidence.
