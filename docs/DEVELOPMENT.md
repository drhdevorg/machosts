# MacHosts – Local development

As of October 25, 2026. macOS 27.0+, Apple Silicon only. Previously verified locally with Xcode 27.1 (27A9275), Swift 6.4, and macOS SDK 27.0. Swift 6 language mode and complete concurrency checking are enabled. UI is MainActor-isolated; package modules have no UI default isolation.

**Current verification:** the full 131-test package run, strict formatting, Release/Debug test builds, localization coverage, and Release signature verification passed for filtered entry controls and atomic bulk changes. The new XCUITest compiled but was not executed after recent automation-initialization failures. Full native acceptance remains open; see [phase 5](verification/phase-5.md).

Latest increment: discoverable profile organization passed 132 package tests, Release/Debug test builds, strict formatting, profile-action localization coverage, and Release signature verification. The isolated menu XCUITest outcome is recorded in the phase-5 report.

Latest independent exchange increment: `.hosts` import/export passed 139 package
tests and Release/Debug test builds. Imports preserve reviewed bytes and create inactive local
profiles; export requires a new filename. Native file-panel acceptance and remaining
phase-7 work are open; see [phase 7](verification/phase-7.md).

Latest JSON increment: version-1 source/folder export and reviewed inactive append
passed 146 package tests, Release/Debug test builds, formatting, localization coverage
and Release signature verification. Native panel/review acceptance remains open.
See [phase 7](verification/phase-7.md) and the [format contract](JSON-EXCHANGE.md).

## Open the project

Open `MacHosts.xcodeproj` with the shared `MacHosts` scheme. The local package `Packages/MacHostsKit` supplies `HostsCore`, `HostsServices`, and `HostsSystem`. There are no external dependencies or project generators. The app target embeds `MacHostsApply` under `Contents/MacOS`.

App bundle ID: `de.machosts.app`, a project constant without team assignment. Manual ad-hoc signing (`-`), no Developer ID or notarization. `OTHER_CODE_SIGN_FLAGS = --options runtime` preserves runtime signature flags even when Xcode disables its automatic Hardened Runtime setting for ad-hoc signing. Check the actual signature flags. The app has no App Sandbox or additional project-specific entitlements. Debug dylib mode is disabled. Only the UI test target disables Hardened Runtime and extra signing flags so XCTest can load its ad-hoc test bundle; app/tool signatures are unchanged.

## Build and test

Run all commands from the repository root without privileges. `/tmp` paths keep generated files outside the project. The coding sandbox blocks Xcode's user manifest cache; Xcode previously required targeted execution approval. Cache environment variables alone do not resolve that restriction. Never redefine `HOME` or `CODEX_HOME`.

```sh
CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules swift test --package-path Packages/MacHostsKit --scratch-path /tmp/machosts-product-package --cache-path /tmp/machosts-product-cache --disable-sandbox

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/machosts-product-derived -packageCachePath /tmp/machosts-product-cache build-for-testing

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/machosts-product-derived -packageCachePath /tmp/machosts-product-cache test-without-building

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/machosts-product-derived -packageCachePath /tmp/machosts-product-cache build

xcrun swift-format lint --strict --recursive MacHosts MacHostsApply MacHostsUITests Packages/MacHostsKit Experiments/NativeEditorProbe

codesign --verify --deep --strict --verbose=2 /tmp/machosts-product-derived/Build/Products/Debug/MacHosts.app
codesign --display --verbose=4 /tmp/machosts-product-derived/Build/Products/Debug/MacHosts.app
codesign --display --verbose=4 /tmp/machosts-product-derived/Build/Products/Debug/MacHosts.app/Contents/MacOS/MacHostsApply
```

Swift Testing checks core parsing/composition, private workspace transactions, recovery, and autosave. Apply tests also cover revision changes, cancellation, duplicate calls, app-save failures, and receipt/readback recovery. The original adapter holds system bytes in memory; a further adapter connects the coordinator end to end to the actual private file transaction engine. Workspace/migration writes use private temporary directories.

System tests execute private backups/journals, atomic replacement, metadata checks, and injected failures. Their adapter creates its own private temporary directory and exists only in the test target; no product destination is selectable. Process tests terminate workers at eight commit boundaries with `_exit(86)` and start independent recovery processes. They cover corrupt/external recovery data and both process locks. Nine further cases terminate during intent/result/recovery saves; four cases exercise a worker surviving app exit, completing normally or receiving SIGKILL before/after rename. Recovery stays blocked while the worker lock is held and preserves newer drafts. Seven retirement-termination cases verify durable replay tombstones. These tests need `swift test` with the documented `swiftpm-testing-helper`; other runners are unverified.

Contract tests ensure unavailable production integration never reports success. The shared `MacHostsUITests/Launch.xctestplan` covers startup and availability plus local profile/editor/organization flows. UI tests need normal local macOS automation authorization; lack of authorization is not a pass. The phase-0 experiment remains separate and need not run for every independent UI/core build.

## Current development status

`HostsCore` supplies parser, profiles, composition, and immutable `ApplyPlan`. `HostsServices` supplies `WorkspaceStore`, autosave, local recovery, and `ApplyCoordinator`. Schema 2 stores pending apply separately from draft/applied state. Schema 1 migrates atomically only after archiving its exact old bytes; older builds reject schema 2.

The coordinator exercises preview, authorization, commit, and receipt/readback reconciliation in tests. Its public production constructor still returns `integrationUnavailable`; no selectable success simulation exists. `SystemWriter.apply()` always throws `integrationUnavailable`. The CLI performs no authorization/file access, rejects root with exit 64, and otherwise exits 69. No functional system writer is hidden behind a test switch.

Gates 2 and 3 passed locally; [phase 4](verification/phase-4.md) is partial. Private fixture evidence covers the transaction engine, coordinator integration, eight restart points, app/recovery save termination, and independent unprivileged worker lifecycles. Product authorization, protected backups/receipts, and gate 4 remain open.

`SystemFileMonitor` observes parent directory and current inode, debounces digest changes, bounds reads, reports errors, and supports explicit restart after directory loss. Shared MainActor `SystemObservationModel` connects it to all app windows. The standard workspace opens on a service actor and retains its process lock. Receipt reconciliation, recovery precedence, read failures, manual refresh/restart, and wake refresh are localized in German/English. Failed workspace startup can be retried without creating replacement empty data. Native multiwindow/wake acceptance remains open.

Observation never resolves pending apply. It distinguishes before/after/other/unreadable bytes and explains the unavailable transaction-record check. `ApplyRecoveryAssessment` separately distinguishes missing journal, active worker, uncertain/unavailable evidence, invalid receipt, and terminal evidence. Store-wide recovery locking excludes concurrent coordinators. Matching bytes alone neither delete orphaned intents nor establish applied state.

Internal orphan retirement is verified on private fixtures under [ADR 0003](decisions/0003-orphan-retirement.md): durable retirement under the worker lock, replay rejection in later processes, fresh before-digest, and no new receipt. Active workers, after/foreign bytes, and errors stay blocked. The coordinator method is internal; default adapter and production UI expose no retirement action. Production transport/authorization/durability evidence remains outstanding.

Gate 0 is deferred under [ADR 0002](decisions/0002-deferred-gate-0.md). Parser, workspace, and UI may continue independently. Local write tests use private fixtures only. Never alter the workstation hosts file or metadata; real privileged integration requires a confirmed disposable VM.

## Open infrastructure

The folder is now a Git repository (commit `1d573ef` at the start of the phase-5 run). CI configuration and formal clean-checkout evidence remain open. Do not invent an Xcode-27.1 CI runner; verify the actual provider toolchain before configuring CI and execute these commands there. Do not lower the deployment target as a workaround.

## Local profile workflow – Phase 5 partial result

`ProfileWorkspaceModel` shares draft/save state across windows and uses `WorkspaceAutosave`/`WorkspaceStore`. MainActor handles values; file work stays on the store actor. Save failures preserve the visible draft and allow retry. External workspace changes block further mutations. Normal quit waits for saving and is refused on failure; SIGKILL can lose unsaved keystrokes. Names are confirmed through Rename; text/activation autosave. Corrupt/newer workspaces are never offered as empty writable data.

`NSTextView` supplies native selection, undo, and find bar. The shared parser derives entries; line switches bind displayed source by digest. Remote text is read-only and can be duplicated as an inactive local profile. Desired activation and actual system state remain separate. There is no apply substitute.

Only Debug accepts `--ui-testing-local-workspace`: a fresh random private temporary workspace, visible test marker, no system observation, path argument, or simulated apply. UI tests use only that mode, disable window restoration, and activate the app explicitly. Release ignores the switch. Diagnostic test workspaces remain under temporary `machosts-ui-*`; no production cleanup is claimed.

### Folders and cross-profile search

Folders use the existing workspace hierarchy. Management supports creation, renaming, reassignment, sibling ordering, and removal preserving profiles/children. Missing parents, cycles, and more than 16 levels reject the entire change. Profile assignment/up/down operates on visible siblings. Folder actions never activate profiles or change composition order; explicit profile up/down updates global profile order.

`Cmd-Shift-F` focuses cross-profile literal case-insensitive search of local/remote drafts, including disabled entries, by name/text line. Trash is excluded. One hit per matching line plus name hits, capped at 200 with a visible notice. `ProfileSearch` runs on an immutable snapshot on its actor; debounce/cancellation discard stale results. Digest-bound UTF-16 ranges reach native selection only for current text. Profile identity keeps undo contexts separate. Native folder/search acceptance remains open after Accessibility/authorization and runner authentication failures; no permissions were changed.

### Editor colors and line numbers

`ProfileEditorStyler` derives UTF-16 spans from the parser on a service actor. The bridge uses temporary layout attributes and rejects stale replies. A native ruler draws visible line numbers only. CR/LF/CRLF, Unicode, a final empty line, and parser-rejected drafts retain correct numbering. Styling does not change source, selection, or undo.

The [native editor probe](../Experiments/NativeEditorProbe/README.md) exercises the actual bridge with in-memory fixtures and light/dark text/ruler renders without Accessibility automation. Earlier evidence: 111 package tests and Release/Debug test builds passed. These are not full UI acceptance, resource measurement, or a resolution of XCUITest authorization.

### Read-only system contents

The system sheet now shows digest-bound complete decoded text with syntax colors, line numbers, selectable/copyable native text, managed-block highlighting, and bounded diagnostics. Read failures/restart/cancellation clear displayed contents. Unsupported encoding is explicit; no lossy conversion. The preceding increment passed 114 package tests, app type-check, formatting, and the extended native probe. Current checks and the read-only preview are described below. Production recovery UI, full native acceptance, and gates 0/4/5 remain open.

### Frozen change preview

“Preview changes” flushes drafts and prepares a frozen plan on a service actor using digest-bound observed contents. It shares ownership checks with the coordinator, includes all enabled drafts, mapping additions/removals with provenance, parser/conflict explanations, and complete read-only current/proposed file views. Changed workspace/generation, read failure, changed digest, or observation restart invalidates the preview until explicitly rebuilt. Observation revision preserves invalidation when equal bytes return after an interruption. Display caps are explicit; file contents are complete.

This is read-only planning, with no authorization, app intent, receipt, or write. A future production Apply must use coordinator preparation/revalidation with fresh system reads. Private UI-test mode has no system contents and correctly reports planning unavailable. The preview increment passed 121 package tests; newer recovery evidence is below. The isolated private-workspace preview-availability UI test passed, while later suites, including that preview test, fail at the private-workspace startup marker with no accessible main window. The launcher terminates the app on marker failure before any editing. Native end-to-end acceptance and gates remain open. Commands/logs are in the phase-5 report.

### Local workspace recovery

Corrupt/missing saved workspaces with a valid previous snapshot now offer native review and explicit local restoration. Complete profile text is read-only in the review; cancellation leaves the workspace unchanged. The store validates current bytes and archives the damaged original before restoration. Unsupported schemas remain read-only. The editor restarts autosave only after restoration; system receipts/pending intents remain subject to system reconciliation. Debug private-workspace mode additionally accepts `--ui-testing-damaged-workspace` to seed a fixed damaged private fixture; Release ignores it. Verification and native acceptance limits: [phase 5](verification/phase-5.md#follow-up--explicit-local-workspace-recovery-october-26-2026).

### Native workspace commands

Focused scene values route New/Save, Find/Replace, cross-profile search, preview, folders/trash, and system status to the active workspace window. Workspace sheets disable these commands. Find/Replace sends a one-time request to the selected native editor; Replace requires a writable local profile. Cmd-F / Option-Cmd-F opens the AppKit bar, Shift-Cmd-F focuses workspace search, and Shift-Cmd-P opens the read-only preview. Release/Debug test builds, localization coverage, signature/format checks, and the in-process bar probe passed; menu/multiwindow/VoiceOver acceptance is still open. See the phase-5 report for exact evidence and limits.

### Multiple workspace windows

Shift-Cmd-N opens another window on the shared workspace. Selection, search, find requests, and sheets belong to each window. Draft edits/autosave remain shared. Each native source editor owns an undo manager; remote changes to its displayed draft invalidate only its stale history. Read-only profiles remain selectable. The extended native probe verifies editor isolation and shared-draft synchronization across windows; full SwiftUI window/menu acceptance remains open. See the latest [phase-5 evidence](verification/phase-5.md).

### Deleted profile review

Trash supports name filtering, deletion dates, local/remote identification, and complete read-only source inspection using the native editor and Find. Closing the review leaves data unchanged. Explicit restore preserves source and identity, restores inactive, and selects the restored profile only in the initiating window. Failed restores keep the review open with a visible error. The full 127-test run covers private persistence and combined live/trash limits; native UI/VoiceOver acceptance remains open. See the latest [phase-5 evidence](verification/phase-5.md).

### Filtered entry controls

Entry switches filter original record text literally and case-insensitively, including aliases/comments, with all/enabled/disabled state filters. Native links select digest-bound complete source lines. At most 200 records are displayed; bulk actions explicitly include all matches. Bulk changes validate all selected records and the source digest atomically, preserve original bytes elsewhere, and save one draft revision. They never enable ordinary comments or alter desired profile activation. Remote/read-only and incomplete-limit views disable mutations. The full 131-test package run and Release/Debug test builds passed; native UI acceptance remains open. See the latest [phase-5 evidence](verification/phase-5.md).

### Preview source navigation

Current profile origins in added mappings, conflicts, and parser diagnostics link to exact source lines in the initiating window. Frozen-input and current-digest checks reject stale navigation; removed mappings retain informational provenance. Referenced profiles are indexed once on the preview actor. The native preview now includes observation revision to invalidate equal-byte restarts/read failures. Full 134-test package run and nine focused preview tests passed; Release/Debug test builds passed. Native sheet/focus/VoiceOver acceptance remains open; see the latest [phase-5 evidence](verification/phase-5.md).

### Selective JSON import

The JSON review now supports per-profile inclusion, select/deselect all, and either
all folders or only required ancestor folders. Complete input validation precedes
selection; the current workspace budget is checked atomically when confirming.
The full 149-test package run passed. Release/Debug build and native acceptance
evidence is recorded in [phase 7](verification/phase-7.md).
