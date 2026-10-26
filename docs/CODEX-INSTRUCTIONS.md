# MacHosts – Coding instructions for Codex

This is the implementation working agreement. First read the [Product outline](PRODUCT-OUTLINE.md), [Architecture](ARCHITECTURE.md), and [Implementation plan](IMPLEMENTATION-PLAN.md). Sources and original assessment are in [RESEARCH.md](RESEARCH.md). These describe target behavior; inspect actual code before claiming functionality exists.

## Deferred gate 0

The user's explicit request establishes [ADR 0002](decisions/0002-deferred-gate-0.md): gate 0 no longer blocks independent development. Phases 1–3 are authorized; further local flows may use private fixtures and an unavailable system writer. Production privileged operation and integration/release approval still need gate 0. This supersedes contrary ordering requirements and older phase-0 restrictions in the prompt templates below. A general continuation proceeds with the next independent block.

## Binding decisions

macOS 27.0+, arm64, Swift, SwiftUI, German/English app, MIT. Distribution without Apple account/Developer ID/notarization, with technically required ad-hoc signing. System authorization on explicit apply; no persistent root service in V1. Changes remain until manually disabled. V1 includes local profiles, entry switches, folders, menu bar, editor, preview, conflicts, backup/recovery, remote sources, and documented SwitchHosts import. No automatic apply of downloads. Repository documentation and developer-facing text use English; preserve app localization and intentional multilingual test data.

Documentation creation alone does not authorize implementation/publication. Once the user requests a phase or the whole plan, perform necessary reversible implementation without repeated routine approvals. Do not ask already answered product questions again.

## Scope, pace, and token efficiency

The work preference confirmed October 25, 2026 applies to future coding runs: complete as many related steps and executable phases as possible per run. “Continue coding” continues within agreed scope; do not stop after a tiny fix awaiting another prompt. Explicit limits and required gates remain binding; this preference does not pass an open gate.

Before editing, choose a substantial coherent block based on dependencies and actual status. Prepare implementation, error handling, and meaningful tests together. Batch tests/build/format checks at milestones. Verify required gates before dependent work. Fix failures and rerun relevant checks without needlessly repeating unchanged successful suites.

For efficient execution:

- Use `rg` to locate files/symbols; read targeted ranges and batch independent reads. Do not reload unchanged instructions in full in the same context.
- Reuse patterns/shared domain logic. Avoid unnecessary libraries, generators, architecture changes, speculative features, and unrelated cleanup.
- Test observable behavior, data integrity, and failure boundaries. Parameterize common contracts; avoid meaningless duplicates and cosmetic tests.
- Use caches/incremental builds; clean builds need a concrete reason or evidence requirement. Log lengthy output locally and report relevant errors/results.
- Verify documentation consistency/references directly without Swift builds/runtime tests. Update status/evidence together after substantial milestones.
- When blocked, complete independent permitted work. If none remains, identify the blocker and required next step; do not create a chain of tiny prototype changes just to show activity.
- Make routine decisions independently, provide brief result/direction updates, and finish with changes, actual checks, and remaining limits. No subagents without an explicit request.

## Code and structure

1. Own product logic is Swift only. Use system frameworks directly. AppKit is permitted for the editor behind a small SwiftUI bridge. No WebView, HTML/JS interface, or other language runtime.
2. Swift 6 language mode with complete concurrency checking. UI explicitly on Main Actor; Core independent. Record compiler/SDK in the development guide. No invented build settings/version switches.
3. Use `struct`/`enum` and `Sendable` for domain values, actors for shared mutable state, `@Observable` for UI models. Recheck revision/transaction after `await`. No `DispatchSemaphore.wait()` to bridge async synchronously.
4. Small understandable types/methods. Protocols at real store/authorization/system-file/network boundaries, not for every type. No generic repository/event-bus/plugin framework.
5. No `try!`, unchecked force unwraps, or silent `try?` at I/O/security boundaries. Type errors, preserve internal context, and present understandable user messages. Do not log full content.
6. No blanket `@unchecked Sendable`, `nonisolated(unsafe)`, or disabled warnings. Narrow exceptions require written justification and verified synchronization. Confine unsafe/POSIX code to the required file boundary and verify it there.
7. Follow Swift API Design Guidelines and `swift-format`; use English identifiers/comments/developer text. Comments explain contracts and nonobvious reasons rather than narrate obvious code. Document public APIs and dangerous file transactions.
8. Add frameworks/libraries only for actual value. Start without external runtime dependencies. No unnecessary generators, SwiftData layer, or state-management library.
9. One domain implementation for windows, menu bar, import, and tool. Do not rebuild parser/composer in preview views. Preview and privileged write validate the same frozen plan/rules.

## Safety and data integrity

- Never run the app as root. No password fields/cache, broader hosts permissions, special `sudoers`, or deprecated `AuthorizationExecuteWithPrivileges`.
- Execute the tool only through the phase-0-proven trust/authorization path. Ad-hoc signing or equal bundle IDs alone prove no identity. Never run an unchecked user-writable binary as root.
- No user-defined shell commands. Never interpolate product data into shell/AppleScript syntax. A fixed OS bridge transports narrowly validated arguments only; test escaping separately with malicious inputs.
- Version/bound privileged requests; fixed target, no arbitrary read/write/cleanup paths. Repeat validation in the tool. No hidden production test mode accepting arbitrary targets.
- Back up original bytes/metadata and durably journal before writes. No backup, no write. Reject existing symlinks/hardlinks, unexpected types, and unsafe directories.
- Preserve foreign bytes outside the block. Broken markers block; never adopt foreign management. Restore only against freshly checked actual state; no automatic overwrite after crash.
- Separate desired/applied snapshots. Success requires readback/receipt; cache status is separate. Cancellation/timeout after commit starts can mean unknown outcome.
- No automatic download/apply, TLS exceptions, or cloud/telemetry requirement. Bound remote/import sizes while reading. Old/failed responses cannot overwrite valid state.
- Never modify the workstation's local hosts file through coding, tests, demos, manual probes, build/helpers, or recovery. This includes `/etc/hosts`, `/private/etc/hosts`, aliases/links, permissions, ownership, and metadata. Restoring afterward does not authorize a local test write. Normal write tests use private fixtures/injected filesystem and authorization adapters only. All real privileged system writes require a confirmed disposable VM whose hosts file is the deliberately isolated target.

## UI rules

Use native controls, `NavigationSplitView`, `Settings`, `Commands`, `MenuBarExtra`, SF Symbols, and string catalogs. System appearance without custom glass over the editor. Consider keyboard focus, VoiceOver, and undo from the start. Surface implementation details only when they support a user decision.

Main-window switches edit desired state. Menu quick actions preview all affected changes. A changed draft of an active profile must not appear already applied. The system-file view is read-only actual state; edits go through profiles/shared apply service.

## Per-phase workflow

1. Inspect status/code. Choose the first open phase and identify dependencies/nonnegotiable gates.
2. Implement a substantial coherent result, batching related steps. Do not jump to a dependent phase to disguise an unresolved gate.
3. Batch relevant tests/static checks at milestones, no later than the required gate. Test behavior/contracts, not mirrored internals. Inject critical transaction failures.
4. Review the diff for bugs, privilege expansion, unnecessary dependencies, logged secrets, false success, and incomplete recovery.
5. Update `docs/verification/phase-N.md` and plan status. Distinguish passed checks from unexecuted ones; assertions do not replace evidence.
6. Within scope, continue to the next phase in the same run after passing its gate. General continuation should finish multiple executable steps/phases where possible. Finish briefly with behavior, verification, limits, and next phase.

No subagents without explicit request or otherwise applicable instruction. No publication, PR creation, or network communication merely as a side effect of local implementation. Never call planned functionality delivered.

## Starting prompt: first implementation phase

```text
Implement MacHosts according to docs/PRODUCT-OUTLINE.md, docs/ARCHITECTURE.md,
docs/IMPLEMENTATION-PLAN.md, and docs/CODEX-INSTRUCTIONS.md.
Initially complete phase 0 only.
Respect confirmed product decisions without asking again.
Demonstrate the account-free privileged write path using a narrow Swift tool;
an admin dialog alone is insufficient. Verify tool provenance, request integrity,
cancellation, and recovery. Perform real system writes only in a disposable
macOS-27 VM, never on the workstation's hosts file.
If no VM is available, complete independent prototype/tests and document missing
evidence; do not mark gate 0 passed. Create ADR 0001 and the phase report.
If safety cannot be demonstrated under confirmed constraints, provide concrete
alternatives rather than weaken contracts. Under ADR 0002, gate 0 may be deferred;
continue independent work with an unavailable system writer.
```

## Follow-up prompt: further phases

```text
Complete as many related open steps and phases of the MacHosts implementation
plan as possible in this coding run. First read current status, relevant evidence,
and coding/architecture contracts. Check all required gates have passed.
Implement substantial functional blocks and batch tests at their completion;
verify required gates before dependent phases.
Never modify the workstation's local hosts file.
Verify/document the result, update status and phase report, and report remaining
risks and unexecuted checks. Preserve confirmed product decisions.
```
