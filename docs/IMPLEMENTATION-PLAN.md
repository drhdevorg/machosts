# MacHosts – Phased implementation plan

As of October 25, 2026. Product direction is confirmed. Phase 0 is prepared locally, including request validation, size limits, descriptor-checked reads, journaled fixture restore, unsafe-artifact preflight, rejection of files writable by others, and consistent/unambiguous stored transaction JSON. Privileged evidence remains outstanding. VM tests are postponed at the user's request; [ADR 0002](decisions/0002-deferred-gate-0.md) explicitly defers gate 0.

Phases 1–3 are implemented and locally checked; gates 2 and 3 passed locally, while formal phase-1 clean-checkout/CI evidence remains open. Phase 4 includes coordinator, persistent intents, schema-2 migration, private transaction engine, receipt/readback recovery, actual process termination/restart, observation, shared recovery locking, and internal orphan retirement. Production transactions and gate 4 remain open. Phase 5 includes local profiles, native editor, autosave, trash, folders, cross-profile search, colors/line numbers, read-only system contents, frozen read-only change previews with conflict provenance, and explicit local workspace recovery. Latest evidence: 149 package tests, formatting, and Release/Debug test builds passed, including independent `.hosts`/version-1 JSON exchange ([phase 7](verification/phase-7.md)); the previous missing CoreSimulator framework build blocker no longer reproduces. Full native acceptance and gate 5 remain open. Reports: [phase 0](verification/phase-0.md), [phase 4](verification/phase-4.md), [phase 5](verification/phase-5.md).

## Workflow and gate rules

Respect functional dependencies; ADR 0002 removes only the blanket chronological gate-0 block. Each phase produces code/artifacts, suitable verification, a report in `docs/verification/phase-N.md`, and updated status below. Evidence states environment, exact commands/actions, result, relevant logs/artifacts, and remaining risks. “Not executed” means neither “passed” nor automatically “product failure.”

Complete as many related steps and, after gates pass, multiple phases as practical per coding run. Do not stop after every small correction. Batch tests/builds/formatting at substantial milestones; required gate evidence still precedes dependent work. Detailed efficiency rules: [Scope, pace, and token efficiency](CODEX-INSTRUCTIONS.md#scope-pace-and-token-efficiency). This preference does not pass a gate or cancel postponed VM tests.

Without a test environment, prepare independent work while dependent gates remain open. A mock cannot pass privileged integration. Never modify the workstation hosts file, its permissions, ownership, or metadata through coding, tests, demos, or scripts. Actual system writes require a prepared, confirmed disposable macOS-27 VM. Targeted VM tests belong to the later implementation work.

The [architecture](ARCHITECTURE.md) security contracts apply in every phase. Present real product/architecture obstacles with concrete alternatives. Make routine decisions within those contracts, document them, and continue.

## Deferred gate 0

Phases 1–3 may be fully developed, and phases 4–7 may use private fixtures/an unavailable writer. Functional dependencies still apply; partial completion is not integration approval. Gate 0 is mandatory before production privileged operation, phase-4 integration completion, and overall phase-8/9 approval. VM tests remain postponed.

## Status

| Phase | Intended result | Current status | Depends on |
| --- | --- | --- | --- |
| Planning | Research, user decisions, architecture, instructions | Complete | — |
| 0 | Proven safe account-free write path | Local preparation complete; gate open, VM postponed | Planning |
| 1 | Reproducible project and check commands | Implemented; local checks passed; clean-checkout/CI evidence open | Planning; gate 0 deferred |
| 2 | Parser, profiles, conflicts, composition | Implemented; gate 2 passed locally ([evidence](verification/phase-2.md)) | 1 |
| 3 | Workspace storage and unprivileged recovery | Implemented; gate 3 passed locally ([evidence](verification/phase-3.md)) | 2 |
| 4 | Production apply/backup/recovery | Partial: coordinator/private engine, process lifecycles, observation, durable orphan retirement verified on fixtures; gate open | 2, 3; gate 0 for real integration |
| 5 | Native app, editor, main workflows | Partial: profiles, folders, search, styled editor, system contents, frozen read-only preview, local workspace recovery; native acceptance/gate open | 4 |
| 6 | Menu bar, login start, system diagnostics | Open | 5 |
| 7 | Remote profiles and migration/export | Partial: bounded `.hosts` and version-1 JSON selective append/export; remote/SwitchHosts/replacement and native acceptance open | 3, 5 |
| 8 | Hardening, accessibility, performance, beta | Open | 6, 7 |
| 9 | Release artifact and production acceptance | Open | 8 |

## Phase 0 – Feasibility before product integration

**Goal:** prove account-free distribution and an acceptably safe privileged path can work together. An administrator dialog alone is insufficient.

**Tasks:**

1. Check installed toolchain/SDK and documented authorization paths; update research sources if necessary. Plan tests on disposable files first and privileged tests only in the VM.
2. Build a minimal Swift prototype under `Experiments/AuthorizationProbe/`: unprivileged UI, narrow request, short-lived Swift tool, ad-hoc build without team/account. No production editor/profile manager.
3. Test the OS authorization bridge on macOS 27, including spaces, quotes, and Unicode in paths. Profile text is data only; injection attempts must not create commands. Document and minimize shell/AppleScript use.
4. Establish privileged code/library provenance. Investigate replacement after hash check, tampered requests, symlink swaps, replay, and TOCTOU. An install path/bundle ID alone is no trust proof. If protected staging is required, specify its complete bootstrap/cleanup.
5. Investigate cancellation, wrong/missing authorization, timeout, tampering, and process termination. Passwords belong only in the OS dialog; no custom input/storage.
6. Test no-op, addition, removal, readback, and restore against VM hosts; verify exact original bytes afterward. Include a quarantined ZIP download or realistic quarantine properties and individual first-launch approval.
7. Write `docs/decisions/0001-privileged-write.md` with examined options, chosen mechanism, trust boundaries, evidence, residual risks, and unsupported cases. Do not relabel open vulnerabilities as accepted residual risk.

**Gate 0:** an account-free prototype runs in a fresh macOS-27 VM and proves narrow safe writes, cancellation, and recovery without deprecated `AuthorizationExecuteWithPrivileges`, broad `sudoers`, permanent hosts write permissions, or root GUI. Executable provenance and request integrity are demonstrably secured. Without evidence, keep “not passed” and discuss concrete alternatives. ADR 0002 permits independent product work; an unavailable writer must never simulate success.

## Phase 1 – Project, toolchain, quality foundation

**Deliverables:** `MacHosts.xcodeproj`, architecture-aligned local package, app/tool targets, shared schemes, minimal native start view, string catalog, tests. MIT license with correct copyright; documented bundle-ID constant without team dependency.

**Tasks:**

- Verify SDK/deployment target 27.0, arm64, Swift 6 language mode, strict concurrency. Choose UI default isolation deliberately; do not accidentally isolate entire Core/System modules to MainActor.
- Exclude automatic signing/team requirements; configure ad-hoc tool embedding/signing from inside out. Prove needed entitlements and Hardened Runtime.
- Commit `swift-format` configuration, fix warnings in our code, avoid dependencies merely for project generation.
- Record exact build/test/format commands in `docs/DEVELOPMENT.md`. No `sudo`/password commands in the normal developer pipeline.
- Add CI only for actually available macOS/Xcode runners. If unavailable, document the infrastructure gap and keep local verification possible; never silently downgrade toolchain.

**Verification/gate 1:** a clean checkout without Apple login builds app/tool, app starts, minimal core tests and formatting run. Shared schemes/test plans work from CLI. Document build/signature results. A build alone proves no system integration.

## Phase 2 – Parser and pure domain logic

**Deliverables:** `HostsCore` with line-preserving parser, typed profiles, deterministic composition, owned markers, conflict analysis, immutable `ApplyPlan`.

**Tasks:**

- Implement models/normalization per architecture. Entry switches use the reserved profile-comment prefix; ordinary comments remain comments.
- Preserve foreign prefix/suffix bytes, missing final LF, and mixed line endings. Foreign markers remain foreign.
- Diagnose invalid data explicitly; no lossy automatic repair. Check IPv4/IPv6, equal/different IPs, aliases, and provenance.
- Block apply for conflicting mappings, malformed markers, or exceeded limits. Include active foreign system entries in conflicts.

**Verification:** parameterized Swift Testing fixtures for valid/invalid lines, CRLF/LF, empty file, NUL, Unicode comments, IP edge cases, duplicate/injected markers, newline-containing profile names, disabled lines. Check deterministic output, no-op idempotence, exact foreign bytes, removal preserving foreign content. Add generated cases where they actually exercise these invariants.

**Gate 2:** parser/composer test without UI/root/network; relevant invariants pass and no unresolved format ambiguity remains.

## Phase 3 – Persistence and workspace recovery

**Deliverables:** `WorkspaceStore`, atomic JSON snapshots, versioned schema, local trash, debounced autosave, startup app-data recovery.

**Tasks:**

- Use typed DTOs, actor boundaries, and revisions; no direct UI binding to file-writing functions.
- Write a safe same-directory temporary snapshot and publish atomically; serialize independent app instances or reject the second writer explicitly.
- Preserve corrupt/newer formats and open read-only. Never reset to empty data on failure. Back up before migration.
- Store last applied snapshot separately from draft and bind it to a receipt.

**Verification:** restart roundtrip, migration, truncated JSON, unknown version, disk-full/permission injection, concurrent edits, interruption between temp write and rename. No lost confirmed drafts or success after failed save.

**Gate 3:** reconstruct local data after interruption; never confuse draft/applied state. Tests stay in temporary workspaces.

## Phase 4 – Production apply, backups, recovery

**Partial status:** state machine/app recovery verified with private workspaces and explicit adapters. Private engine evidence includes narrow mutations, real backup/journal/rename/readback, coordinator integration, eight process restart points, tampered recovery data, both locks, nine app/recovery-save terminations, and four independent app/worker lifecycles including SIGKILL. Newer drafts survive; active workers block early recovery. Read-only observation and app model are fixture-tested; native UI/wake acceptance remains open. Orphan intents have explicit missing-journal/active-worker/unknown diagnosis and shared recovery locking. ADR 0003 retirement, fresh before-digest, durable replay exclusion, and seven further termination cases are fixture-verified; it creates no receipt or historical non-commit proof. Production UI remains blocked. No production adapter or privileged backup evidence; gate 4 open. See [phase 4](verification/phase-4.md).

**Deliverables:** `ApplyCoordinator`, production authorization adapter under ADR 0001, narrow tool protocol, backup/receipt management, secure transactions, external-change observation.

**Tasks:**

- Transfer prototype contracts into small verifiable Swift components; do not copy experiment code into production without review.
- Execute preflight, immutable preview, authorization, privileged revalidation, backup, journal, rename, readback. Apply the same rules to disable/controlled restore.
- Reconstruct across app restart; detect hash/revision changes across `await`; serialize double clicks/processes.
- Verify a fixed DNS-cache operation separately. Check actual resolution through the system resolver; `dig` is no hosts-effect test.
- No arbitrary production paths. Temporary paths only in internal test components; no hidden privileged CLI destination switch.

**Verification:** normal integration on private files plus a real-target VM matrix: success, no-op without authorization, user cancellation, permission/backup errors, stale plan, external mutation, missing/broken markers, tampered requests, symlink/hardlink, disk full, termination before/after rename, after write/before app save, contradictory readback, cache-flush failure. Restore exact VM original bytes. Test multiuser behavior and embedded-tool updates.

**Gate 4:** tests exclude false applied status and silent foreign data loss within documented contracts. Journal/receipt recovery is evidenced for every commit boundary. Document windows against noncooperating writers. No unresolved serious privilege-boundary defect.

## Phase 5 – Native main app and editor

**Partial status:** shared `ProfileWorkspaceModel` supports creation, rename, inactive local duplication, desired activation, ordering, trash/inactive restore, autosave, visible errors/retry, save before normal quit. Native editor has selection/undo/find bar, parser diagnostics, digest-bound switches, colors, line numbers. Folders validate hierarchy and preserve data on removal; cross-profile search has bounded results/digest-bound UTF-16 jumps. Read-only system contents, frozen read-only change previews with mapping differences/conflict provenance, and explicit local workspace recovery are implemented. A full 123-test run plus three focused recovery tests (124 tests now present), formatting, and Release/Debug test builds passed. The latest isolated recovery UI test failed during automation initialization before running its body. The previous framework build blocker no longer reproduces. Full native acceptance, committing preview/production recovery UI remain open; no system write or simulated success. [Evidence](verification/phase-5.md). Gate 5 not passed.

**Deliverables:** complete local workflow, SwiftUI main window/sidebar, `NSTextView` bridge, profile/system views, preview, understandable errors.

Window-scoped native menus now expose Find/Replace, search, preview, organization, and save commands; Release/Debug test builds and the extended in-process editor probe passed. Menu/multiwindow acceptance remains open.

Window-local selection and per-editor undo now isolate workspace windows while sharing drafts/autosave. New Window uses Shift-Cmd-N; the two-window native editor probe passed. Full window/menu/selection acceptance remains open; see the phase-5 report.

Diagnostic navigation now selects digest-bound source lines; 125 package tests, Release build, formatting, and the extended native editor probe passed. Full diagnostic-button/VoiceOver acceptance remains open; see the phase-5 evidence.

Trash review now includes deleted-name filtering, deletion dates, complete read-only native source inspection/Find, and explicit inactive restoration. The full 127-test package run, Release build, and Debug test build passed; native trash acceptance remains open. See the phase-5 report.

Entry controls now provide literal/state filtering, source navigation, and atomic digest-bound enable/disable for all matching records. Four new contract tests passed in the full 131-test run. Native control acceptance remains open; see the phase-5 report.

Profile organization is now exposed through the window-scoped Profiles menu and detail controls, with inactive-copy selection and sibling-boundary availability. The full 132-test package run, Release/Debug test builds, formatting, localization, and signature checks passed. Native acceptance remains open; see the phase-5 report.

Preview source links now connect current mapping/conflict/diagnostic origins to digest-bound lines in the initiating window. Observation revision is wired into native preview invalidation. Full 134-test package run, nine focused preview tests, formatting, and Release/Debug test builds passed; native navigation acceptance remains open.

**Tasks:**

- Small profile/editor/preview/recovery/settings views; shared injected app model/services. No generic state-management library.
- Profile/folder actions, order, trash, native focus/selection, undo/redo.
- Parser-derived diagnostics/switches. Clearly read-only remote content with local duplication as editing path.
- Visible local autosave and “Not applied.” Editing an active profile does not change system bytes until explicit application.
- Apply shows the whole frozen plan, conflict causes, system-wide impact. Replan if anything changes during preview.
- German/English string catalogs from the start; no hardcoded service text copies. Native New/Search/Undo/Apply commands without text-input shortcut conflicts.

**Verification:** XCUITest with injected unprivileged system environment for Create → Edit → Toggle → Preview → Apply → Disable → Recovery. Cancellation/errors preserve actual state. Manual native checks for undo, selection, large clipboard, search jumps, switches, keyboard navigation.

**Gate 5:** complete local main workflow without Terminal, no placeholder in the core path; UI and actual system integration evidenced separately.

## Phase 6 – Menu bar, login, diagnostics

**Deliverables:** `MenuBarExtra`, reliable close/reopen lifecycle, optional login start, diagnostics.

**Tasks:**

- All actions use the shared `ApplyCoordinator`; show applied profiles/draft differences separately.
- Closing the main window leaves the menu app running; Quit exits without resetting hosts. Explain once when needed, not with repeated warning modals.
- Quick actions use preview/admin approval and show all existing unsaved/unapplied changes.
- Verify opt-in `SMAppService.mainApp` in an account-free build. Show OS status, not a desired boolean. Test moves, updates, OS disable.
- Detect system changes including atomic replacement. Report resolver, last apply, DNS cache status accurately without browser/proxy-cache guarantees.

**Gate 6:** menu/window actions never diverge. Close, quit, login, sleep/wake, external changes, app updates are evidenced. No automatic login/root process without deliberate setup.

## Phase 7 – Remote profiles and exchange/migration

**Partial status (October 26):** native `.hosts` import review/inactive insertion, explicit source/enabled-entry export, and version-1 JSON review/selective append/export implemented. Full 149 package tests and Release/Debug test builds passed; native file-panel acceptance and remaining exchange/remote work remain open. [Evidence](verification/phase-7.md). Gate 7 not passed.

**Deliverables:** bounded HTTPS downloads, last valid cache, optional in-process refresh, own export format, documented SwitchHosts import.

**Tasks:**

- Implement architecture limits, TLS, redirects, stale-response rejection, cancellation. Handle ETag/304, offline, invalid responses.
- Preview remote updates and require explicit system apply; never auto-apply.
- Own MacHosts JSON/`.hosts` fixtures; local deterministic import without network/system effects.
- Inspect official representative v4/v5 SwitchHosts exports and document format/version/source. Target one representative v4 export and the researched v5 export; promise versions only with fixtures. Do not copy large third-party datasets merely for tests.
- Import folders/text/URLs, remap IDs, disable activation. Resolve groups only unambiguously; report unknown features, cycles, incompatibility precisely. Never modify existing SwitchHosts system blocks.
- Preview append/replace, back up before replacement, support safe reimport and clear warnings. No silent truncation at limits.

**Verification:** local URLSession servers/stubs for timeout, oversize, redirect chains, TLS errors, stale responses, deletion during download. JSON corruption, unknown versions, ID collisions, cycles, nested folders, roundtrip. A real public HTTPS request supplements deterministic tests.

**Gate 7:** remote failures preserve valid state and never change the system. Every supported import version has fixtures and is listed in the user guide. No blanket full SwitchHosts compatibility claim.

## Phase 8 – Hardening and beta acceptance

**Deliverables:** verified failure boundaries, accessible native UI, measured performance, complete recovery/operation guide.

**Tasks:**

- Review actual privilege/import/remote boundaries; repeating architecture text is not security evidence.
- Rerun full failure/crash matrices; fix data-loss/privilege defects.
- Test VoiceOver, full keyboard/focus after sheets, contrast, reduced transparency/motion, light/dark, longer German strings.
- Measure Release budgets from the product outline with device/dataset details. Do not remove features merely to shrink binaries.
- Verify offline operation, idle without downloads, redacted logs, permissions, retention, diagnostic export. Inventory dependencies/licenses.
- Create `docs/USER-GUIDE.md`: first launch, activation, conflicts, remote, backup, TLS/resolver limits, migration, complete removal.

**Gate 8:** no known release-blocking crash, data-loss/privilege bug, or unverified success message. Critical flows accessible, resources measured, harmless limits documented. Unexecuted tests remain open.

## Phase 9 – Packaging and production release

**Deliverables:** Release build, ad-hoc signed app ZIP (optional DMG), SHA-256, release notes, complete approval evidence. V1 has no automatic updater.

**Tasks:**

- Reproducible build/package from a clean project with recorded Xcode version. No bit-identical-build claim without evidence.
- Sign inner binaries then bundle, verify integrity. Distinguish expected Gatekeeper rejection without Developer ID from broken/invalid signatures.
- Install the actual quarantined download in a fresh macOS-27 VM; approve first launch individually, use local/HTTPS profiles. No Developer account on the test system.
- Update a prior test build with workspace, active block, backups. Recovery/downgrade only with proven schema compatibility; no blind data downgrade.
- Document/test removal: deliberately disable own entries, disable login start, remove app. App/protected backups only through narrow approved cleanup; no general privileged `rm` or removal of foreign lines. Finder-only app removal leaves hosts changes active; explain this.
- Complete `docs/verification/release-1.0.md` with all gate results, supported OS/import versions, artifact digest, limits, environment.

**Gate 9 / Definition of done:** all gates evidenced/passed; clean build, formatting, core/integration/UI tests, real VM flows, and actual-artifact install/use/update/restore/removal succeed. Only then claim production readiness. Publication requires a later explicit request; a local artifact may be fully checked beforehand.

## Shared verification commands

The `MacHosts` scheme and UI test plan exist. Exact cached commands are in [Development](DEVELOPMENT.md); historical bootstrap results are in [phase 1](verification/phase-1.md). Short forms outside the coding sandbox:

```sh
swift test --package-path Packages/MacHostsKit
xcrun swift-format lint --strict --recursive MacHosts MacHostsApply Packages/MacHostsKit
xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Release -destination 'platform=macOS,arch=arm64' build
xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -destination 'platform=macOS,arch=arm64' test
```

Tests are unprivileged by default. VM system tests are a separate deliberately started suite with restore verification; never attach them to `swift test`. Repeat successful checks only for relevant changes, failures, or unresolved risks.
