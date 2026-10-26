# Phase 5 – Local profile workflow (partial completion)

As of October 25, 2026. **Phase 5 started; gate 5 not passed.** Independent development under ADR 0002; production authorization remains deferred. Gates 0 and 4 remain open. Sections below preserve successive historical milestones; later sections supersede earlier missing-feature statements. Current state: profiles/folders/search/styled editor/system contents, frozen read-only preview, local workspace recovery, native commands, window-local selection, and deleted-profile review are implemented. Production recovery and full native acceptance remain outstanding; local build evidence appears below.

## Initial implementation

- Shared MainActor/Observation `ProfileWorkspaceModel` for local drafts: create, rename, source edit, desired activation, inactive local duplication, ordering, trash/inactive restore. Profiles move only to local trash.
- Reused `WorkspaceAutosave`/`WorkspaceStore`. UI model debounces and obtains confirmed save status through explicit flush; `WorkspaceAutosave.schedule` can schedule without a second timer. Validate revisions, profile/workspace limits, names before accepting changes. Invalid hosts syntax remains a saveable editable draft with parser diagnostics.
- Saves behind the actor/file boundary. Newer edits during save are saved afterward; concurrent flushes share one operation. Errors preserve visible draft, offer retry, claim neither saved nor applied success. External workspace changes block mutations. Read-only changes update observation even without a new generation.
- Normal quit waits for the latest draft; save failure keeps the app open with an explanation. SIGKILL/crash can lose edits within the unsaved debounce window; no promise of lossless unpersisted keystrokes.
- SwiftUI sidebar/detail with `NSTextView`: monospace, native selection/undo/find bar, plain text without automatic typography. Profile identity gives separate undo context. Programmatic switches/rejected edits invalidate old undo offsets. Full manual find/undo acceptance remains open.
- Shared Core parser diagnostics/entry switches; switches verify displayed digest. Remote source read-only; duplicate creates inactive local profile/new ID.
- Desired activation, local save status, and “Not applied to the system” stay separate. Draft saves preserve existing receipts/pending intents. System status accessible by sheet. New text in German/English catalog; source/entry data are not translation keys.
- Native New Profile/Save commands. No production writer, apply simulation, or false system success checkmark.

## Environment and isolation

Xcode 27.1 / Swift 6.4, Apple Silicon, macOS 27.0+, Swift 6 concurrency checking. Clean Git commit `1d573ef` at the original run start; changes uncommitted. Git now exists, but formal clean-checkout/CI evidence remains open.

New model tests use fresh private temporary workspaces. Only Debug offers `--ui-testing-local-workspace`: random private directory, visible test marker, no system observation, path argument, or simulated apply. UI tests use only this mode. Release ignores it. Diagnostic workspaces remain under temporary `machosts-ui-*`.

These tests neither read nor changed workstation hosts/standard workspace. No system authorization, root execution, VM test, or publication.

## Initial actual checks

Commands/cache paths from [Development](../DEVELOPMENT.md):

```sh
CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules swift test --package-path Packages/MacHostsKit --scratch-path /tmp/machosts-product-package --cache-path /tmp/machosts-product-cache --disable-sandbox

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules swift test --package-path Packages/MacHostsKit --scratch-path /tmp/machosts-product-package --cache-path /tmp/machosts-product-cache --disable-sandbox --filter 'editor|profileEditing|remoteProfile|profileEditor'

xcrun swift-format lint --strict --recursive MacHosts MacHostsApply MacHostsUITests Packages/MacHostsKit

git diff --check

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/machosts-product-derived -packageCachePath /tmp/machosts-product-cache build-for-testing

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/machosts-product-derived -packageCachePath /tmp/machosts-product-cache test-without-building

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/machosts-product-derived -packageCachePath /tmp/machosts-product-cache build
```

Results:

- Full run passed: **97 tests: 30 System, 55 Services, 12 Core**, parameterized cases additional; `/tmp/machosts-profile-tests.log`. Includes first seven profile-model tests/existing transaction/process suites.
- Focused all ten profile-model tests passed, including later receipt/intent preservation, external workspace mutation, autosave-after-input cases; `/tmp/machosts-profile-focused-tests.log`. Unchanged suites not repeated.
- Ten tests also cover CRLF/Unicode restart, activation without receipt, duplicate/order/trash/inactive restore, remote read-only, stale line digest, names/limits, saveable invalid syntax, save error/retry, newer edits during save, concurrent flush, read-only newer schemas.
- Debug test build and both XCUITests passed: Create → Rename → Type → visible parser diagnostic → Correct → desired activation → Save → Trash → inactive restore with preserved text. Separate test checks unavailable integration. `/tmp/machosts-profile-ui-tests-retry.log`; bundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_17-59-18-+0100.xcresult`.
- Formatting/diff checks passed; `/tmp/machosts-profile-format.log`.
- Final Release passed; `/tmp/machosts-profile-build-final.log`. No own-code warnings; Xcode skipped AppIntents extraction without a framework dependency.

Initial package build exposed Observation initialization order; fixed before successful run. First Xcode call hit sandbox manifest-cache access; approved retry passed. Initial separate launch test lacked the window in Accessibility, while profile flow already passed. Explicit app activation/ignored saved restoration made both pass. This proves isolated startup, not all window/reopen cases.

## Remaining work at the initial milestone

Colors/line numbers/system contents were missing then and were added below. Frozen preview/production recovery remain open. Full manual acceptance for undo/redo, find/replace, large clipboard, selection, focus/keyboard, VoiceOver, German/English, multiple windows is open. Quit after save failure is implemented without native error-dialog acceptance. No resource/performance acceptance.

Gate 0 blocks production authorization; real apply/disable/recovery and gate 4 remain open. Local UI work does not bypass these dependencies or pass gate 5/release gates.

## Follow-up – Folders and search (October 25, 2026)

Phase/gate 5 remain open.

### Implementation

- Create/rename/reparent/sibling-order folders. Existing validation rejects cycles, missing parents, depth over 16 with no partial mutation. No schema change.
- Removing a folder preserves profiles/children and moves them to its parent. Deleted profiles remain in trash; restoration after former-folder removal places them inactive at top level. Organization preserves source/activation.
- Native manager/sidebar hierarchy paths and profile context-menu assignment. Folder actions do not alter global composition order. Explicit profile up/down moves relative to visible siblings and updates global order. Shared autosave/error handling; sheet remains closable after becoming read-only.
- Literal case-insensitive actor-based cross-profile search of names/source, including remote/disabled profiles; no trash/network/files. One match per line plus name hits, maximum 200 with visible limit notice. Debounce/cancellation reject stale results.
- Digest-bound UTF-16 jumps, not UTF-8 byte offsets. Native view selects/scrolls only current matches, separates undo groups, focuses newly created views after window attachment. `Cmd-Shift-F`/visible search action; German/English catalog.
- Two native tests for assignment/removal and search/selection/undo/profile switch. Missing private-test marker immediately stops editing; isolation failure never proceeds.

### Actual verification

Documented commands/cache paths:

- Initial focused run: 14 profile/search tests passed; `/tmp/machosts-organization-tests.log`.
- After visible-sibling ordering: **105 package tests passed: 30 System, 63 Services, 12 Core**, parameterized cases additional; `/tmp/machosts-organization-all-tests.log`. All **15 profile/search tests**, including five new cases for folder restart/preservation, invalid hierarchy, visible order, literal UTF-16/CRLF/blank/Unicode matches, limits/new snapshots.
- Release passed; `/tmp/machosts-organization-release.log`. No own-code warning; skipped AppIntents step, sandboxed SwiftPM user-cache warnings/private cache run passed.
- Final Debug test build including four UI tests passed; `/tmp/machosts-organization-build-final.log`. Wrong XCTest selector `lastMatch` fixed after first build; first sandboxed Xcode call hit manifest cache, approved retry passed.
- **Native run failed:** initial missing Accessibility window, later “Not authorized for performing UI testing actions.” No successful folder/search flow. `/tmp/machosts-organization-ui.log`; `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_18-07-56-+0100.xcresult`; exported attachments `/tmp/machosts-organization-attachments`.
- Focused search retry failed during runner initialization with canceled authentication (“Canceled by user”); `/tmp/machosts-organization-ui-retry.log`; `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_18-09-16-+0100.xcresult`. No further attempts/permission changes. Earlier two UI passes are historical, not evidence for this extension.
- Final formatting/diff checks passed; `/tmp/machosts-organization-format.log`.

All writes private; hosts/metadata unchanged. Native new-flow acceptance/resource measurement and remaining editor/system/preview/recovery work stayed open. Functional XCUITest/Accessibility access is needed. No production authorization, VM integration, gate approval.

## Follow-up – Editor colors and line numbers (October 25, 2026)

### Implementation

- `ProfileEditorPresentation` derives syntax from `HostsDocument`: UTF-16 address/hostname/comment/disabled/invalid spans; invalid lines red/underlined. No second validator. CR/LF/CRLF/Unicode including surrogate pairs retain offsets/bytes.
- `ProfileEditorStyler` actor, 100 ms debounce, cancellation/current-text check before application. Temporary layout attributes only; text storage/selection/typing/undo unaffected. External mutations retain undo-reset contract. View teardown cancels styling.
- Native vertical `NSRulerView`, logical lines, visible viewport via layout manager/binary search, dynamic width/scroll redraw. Empty text has line 1; final terminator adds editable empty line. Complete numbering independent of partial parse, including BOM/line-limit rejection. Remote read-only, system colors, monospaced digits, German/English accessibility label.
- Six new package tests (parameterized endings additional), another ruler/text/undo/redo XCUITest, reproducible in-process check in `Experiments/NativeEditorProbe` using the actual SwiftUI/AppKit bridge without Accessibility automation.

### Actual verification

- **111 package tests passed: 30 System, 69 Services, 12 Core**, parameterized cases additional; `/tmp/machosts-editor-tests-final.log`. Six new presentation tests cover parser styles, Unicode/UTF-16, CR/LF/CRLF starts, inline comments, snapshots, BOM/more than 50,000 lines. Initial failure was a manually miscalculated UTF-16 expectation; corrected, focused six/full run passed.
- Release passed `/tmp/machosts-editor-release-final.log`; Debug test build with five UI tests passed `/tmp/machosts-editor-debug-final.log`. No own Swift warning; skipped AppIntents step. First sandbox manifest-cache attempt blocked; approved build passed.
- **Native in-process check passed** using [probe commands](../../Experiments/NativeEditorProbe/README.md); `/tmp/machosts-editor-probe-build.log`, `/tmp/machosts-editor-probe.log`. Exact CRLF/Unicode, temporary colors/underline, post-input selection, undo/redo after styling, external replacement/cleared undo, 10,000-line scrolling, stale response rejection. No workspace/hosts opened. Compiler macro server required outside-sandbox execution.
- Light/dark surfaces rendered/visually checked: `/tmp/machosts-editor-text-light.png`, `/tmp/machosts-editor-text-dark.png`, `/tmp/machosts-editor-ruler-light.png`, `/tmp/machosts-editor-ruler-dark.png`. Colors, underline, numbers visible; exact text separately checked. Parent NSHostingView bitmap omitted layer-backed text; direct surfaces rendered fully. No whole-window/VoiceOver acceptance inferred.
- Formatting including probe/diff checks passed; `/tmp/machosts-editor-format-final.log`.
- **XCUITest execution not repeated:** authorization blocker unresolved. New test built only; no permission changes/end-to-end pass claim.

### Remaining limits

Colors/numbers are implemented with model/native-surface evidence. System contents followed in the next section. Frozen preview/production recovery, full multiwindow/keyboard/VoiceOver/find/clipboard acceptance, resource measurement remain open. The 10,000-line check is not a performance benchmark. No production writer, authorization, workstation hosts write, VM integration. Gates 0/4/5 open.

## Follow-up – Read-only system contents (October 25, 2026)

### Implementation

- The system status sheet now shows the complete successfully decoded file in the existing native text view, with selection/copy, find bar, line numbers, syntax colors, and a blue background for the single validated MacHosts block. The view is read-only from construction. It uses the system parser context and its 4 MiB limit rather than the profile parser's 1 MiB limit. Foreign text, Unicode comments, and original line endings remain unchanged.
- `SystemFileMonitor` retains display text and parser diagnostics from the same bounded, identity-checked read that produces the observed digest. The model accepts contents only when that digest matches the queued observation and rechecks its subscription generation after the actor hop. Contents are cleared on read failure, observation restart, termination, and cancellation; a previous successful read is not shown as current after failure. Equal-byte reads reuse the parsed contents.
- Unsupported UTF-8/BOM input has an explicit localized explanation and is not decoded lossily. A parser line-limit error retains the complete display text rather than silently truncating it. Diagnostics show line numbers, up to 20 entries with an explicit limit notice. Malformed or partially parsed marker sequences never receive a managed-block highlight. Valid system markers are no longer styled as illegal profile markers. All new interface text is available in German and English.
- The observation service still has no write capability or recovery authority. The system writer, authorization path, frozen preview UI, and production recovery UI remain open. No gate status changed.

### Actual verification

Existing toolchain: Apple Swift 6.4, target arm64 macOS 27.0. Commands used the existing cache paths from `docs/DEVELOPMENT.md`.

- Full package run passed: **114 tests (30 System, 72 Services, 12 Core)**, parameterized cases additional. Log: `/tmp/machosts-system-contents-tests.log`. Three additional tests cover digest/text coherence, replacement/deletion/failure/cancellation, unsupported encoding/BOM, complete text beyond the parser line limit, Unicode/CRLF highlight offsets, malformed/repeated/reversed markers, and suppression of highlight after partial parsing. Tests use private temporary fixtures only.
- An additional assertion in the existing highlight test verifies system content above the 1 MiB profile limit. Its focused rerun passed; log `/tmp/machosts-system-contents-large-test.log`. The final changed test file also passed strict formatting. No production code changed after the full package run.
- All app source files passed direct Swift type-checking; log `/tmp/machosts-system-contents-typecheck.log` (empty on success). Command:

  ```sh
  xcrun swiftc -typecheck -parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macosx27.0 -module-cache-path /tmp/machosts-product-modules -I /tmp/machosts-product-package/debug MacHosts/MacHostsApp.swift MacHosts/ProfileWorkspaceView.swift MacHosts/NativeProfileEditor.swift
  ```

  Swift macro plugins required execution outside the sandbox. The first sandboxed attempt failed to run those plugins and also identified a missing explicit ignored closure parameter, fixed before the successful check.
- The extended native probe compiled and passed using the compiler/run commands in `Experiments/NativeEditorProbe/README.md`. Logs: `/tmp/machosts-system-contents-probe-build.log`, `/tmp/machosts-system-contents-probe.log`. It checks the actual read-only native text view, selection, exact Unicode/CRLF content, temporary highlight restricted to the managed block, and reruns the existing editor checks. Its light/dark native surface renders, `/tmp/machosts-system-contents-light.png` and `/tmp/machosts-system-contents-dark.png`, were visually inspected. The probe uses in-memory text; no workspace or hosts file is opened. The runtime emitted a hiservices XPC connection warning but completed both PASS checks and exited successfully. This is no full-sheet, VoiceOver, find-bar interaction, or XCUITest acceptance claim.
- Strict recursive formatting passed for app, tool, UI tests, package, and native probe; log `/tmp/machosts-system-contents-format.log`. `git diff --check` passed.
- **Release build blocked before source compilation**: the normal documented `xcodebuild ... -configuration Release ... build` invocation could not load `IDESimulatorFoundation` because `/Library/Developer/PrivateFrameworks/CoreSimulator.framework` is missing. Log: `/tmp/machosts-system-contents-release.log`. The missing framework was confirmed by a read-only path check. No Xcode installation/first-launch repair or permission changes were attempted. Direct type-checking and the native probe do not replace a Release bundle build. Debug test build and XCUITest were not attempted with this broken Xcode prerequisite; the earlier Accessibility authorization blocker is also unresolved.

No workstation hosts read/write, metadata change, privileged execution, authorization, or VM integration was performed. Gates 0, 4, and 5 remain open. The system contents view is implemented with model/native-surface evidence; full native acceptance and a current app bundle build remain outstanding. The older statements above that the system contents view is missing are superseded by this section.

## Follow-up – Frozen read-only change preview (October 25, 2026)

### Implementation

- “Preview changes” saves local drafts first and freezes the entire saved workspace and the latest successfully observed system contents. Planning runs on `ChangePreviewPlanner`, a service actor with no file access, authorization, intent persistence, or write capability. `WorkspaceApplyPlanner` now supplies the same managed-block ownership checks to this preview and `ApplyCoordinator`; existing/unrecognized or externally modified blocks remain blocked.
- The native sheet lists all enabled profiles, added/removed mappings with source locations, append/remove/no-change status, and selectable read-only current/proposed complete file views. The complete views include comment/formatting-only changes that mapping differences do not express. Conflict reports include foreign/profile provenance; parser reports include profile/system origin and line. Mapping/conflict/diagnostic lists and source locations have explicit display caps; the complete file views are not truncated. New interface text has English/German catalog entries.
- Draft/saved-generation changes, read errors, file digest changes, and observation restarts invalidate the frozen preview. `SystemObservationModel.previewRevision` preserves invalidation through transient errors/restarts even if the same bytes return before the next UI render. Equal-byte normal refreshes do not invalidate it. An explicit rebuild is required; obsolete results are hidden. Cancellation discards unfinished results.
- The preview uses observed bytes, not a newly authorized transaction or an apply capability. It cannot be submitted to the unavailable production writer. A future production apply must prepare/revalidate through the coordinator against fresh reads. The sheet explains system-wide persistence and whole-draft scope and offers no simulated Apply action. Pending intents, read-only workspace, unsaved drafts, unsupported encoding, invalid documents, conflicts, and unrecognized managed blocks block planning. Private UI-test mode continues to have no system observation and therefore correctly reports preview unavailability.

### Actual verification

- Full final package run passed: **121 tests (30 System, 79 Services, 12 Core)**, parameterized cases additional. Command: the cached `swift test` command in `docs/DEVELOPMENT.md`. Logs: `/tmp/machosts-preview-tests-final.log` (final), `/tmp/machosts-preview-tests.log` (initial 120-test milestone). Seven new tests cover whole-workspace scope, foreign bytes/Unicode/CRLF, origins/conflicts, parser locations, unowned blocks, unsaved/read-only/unreadable input, pending intent, owned disable/separator preservation, and equal-byte recovery/restart invalidation. All file operations use private temporary fixtures.
- Direct app source type-check passed with the command recorded in the preceding increment: `/tmp/machosts-preview-typecheck-final.log` (final; empty on success), `/tmp/machosts-preview-typecheck.log` (initial). Initial sandbox execution could not launch macro plugins; outside-sandbox execution passed. Subsequent freshness changes are covered by final bundle compilation.
- **Final Release build and Debug build-for-testing passed**, with commands from `docs/DEVELOPMENT.md`: `/tmp/machosts-preview-release-final.log`, `/tmp/machosts-preview-debug.log`. Initial Release milestone: `/tmp/machosts-preview-release.log`. The previously missing CoreSimulator framework blocker did not reproduce; no Xcode installation repair or system permission changes were performed in this run. The first sandboxed build failed on user manifest/cache access; the normal outside-sandbox build passed. Final Release signature verification (`codesign --verify --deep --strict`) passed; `/tmp/machosts-preview-signature.log`. Ad-hoc signature/Hardened Runtime flags were displayed; this is no publisher identity or privileged provenance claim.
- **New isolated XCUITest passed**, `LaunchTests/testPreviewSavesDraftAndRequiresObservedSystemContents`, using `test-without-building -only-testing:MacHostsUITests/LaunchTests/testPreviewSavesDraftAndRequiresObservedSystemContents`. `/tmp/machosts-preview-ui.log`; result bundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_23-24-31-+0100.xcresult`. It creates/edits/enables a private local profile, opens the preview, verifies missing observed contents are explained and no Apply action exists, closes the sheet, and verifies saved draft/source/activation and unapplied status. This does not test a successful full-file preview or grant system access. The earlier Accessibility authorization blocker did not reproduce for this test; no permission changes were made.
- **The five existing UI tests failed on a subsequent batch run**, all at `launchPrivateWorkspace`'s required private-workspace marker assertion before any editing. `/tmp/machosts-preview-existing-ui.log`; result bundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_23-25-26-+0100.xcresult`. Exported hierarchy attachments show the MacHosts application/menu bar but no accessible main window; this run did not report the former authorization-denied error. Artifacts: `/tmp/machosts-preview-ui-failure-all`, diagnostics `/tmp/machosts-preview-ui-diagnostics`. This is not acceptance of folders/search/editor or repeatable native startup. An isolated folder retry also failed at the same marker check (`/tmp/machosts-preview-folder-ui-isolated.log`, result bundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_23-27-46-+0100.xcresult`). A subsequent explicit scene-launch-presentation experiment did not resolve missing-window startup and was reverted; its six-test run failed at the same startup marker before editing (`/tmp/machosts-preview-ui-final.log`; result bundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_23-30-07-+0100.xcresult`), including the previously passing preview test. The isolated preview pass therefore does not establish repeatable native acceptance. The private-workspace launcher now terminates its own app before failing the marker assertion. No editing follows a missing marker.
- Strict recursive formatting passed: `/tmp/machosts-preview-format-final.log`. `git diff --check` and catalog coverage for all new preview literals (English/German) passed.

Gates 0, 4, and 5 remain open. Production apply/recovery, full successful-preview native acceptance (including stale responses/multiwindow), VoiceOver, and VM integration remain outstanding. No workstation hosts write, metadata change, privileged process, or authorization was performed. UI launches requested the Debug private-workspace mode, and every test requires the private-workspace marker before editing.

## Follow-up – Explicit local workspace recovery (October 26, 2026)

### Implementation

- Read-only workspace status now explains corrupt/missing data, unsupported schema, unsafe/unreadable files, interrupted saves, external changes, and failed migrations in English/German. Read-only workspaces no longer display the misleading “Local drafts saved” success label.
- A valid previous snapshot is offered for review only for the store's `corruptSnapshot` state. The native review sheet lists saved profiles and desired activation, provides selectable read-only complete profile text, shows saved generation/folder/trash counts, and explains replacement of local drafts and preservation of the damaged original. Cancel performs no recovery. Unsupported schemas are never offered a downgrade.
- Explicit restoration uses `WorkspaceStore.recoverPrevious`, including current-byte validation and an archive of the damaged original. The shared editor blocks mutations/overlapping recovery while restoring, then reloads persisted draft state and starts autosave again. Failures retain read-only state and show a localized error; the sheet directs reopening before another attempt. Previously stored receipts/pending intents are preserved by the existing store operation; this action neither writes the system file nor resolves system transactions. All windows share the recovered editor.
- Only the existing Debug private-workspace mode recognizes the additional fixed `--ui-testing-damaged-workspace` fixture option. It seeds two local saves in its fresh random temporary directory, damages that private snapshot, and opens it normally. No user path, system observation, writer, or success simulation is accepted. Release ignores the options. The new isolated UI test checks review, cancellation, restored source, editing availability, and unapplied status.

### Actual verification

- Full package run passed **123 tests (30 System, 81 Services, 12 Core)**: `/tmp/machosts-local-recovery-tests.log`. Two new model tests cover explicit restoration, no mutation on review, exact damaged-file archive, restored editing/saving, refusal after completion, changed disk bytes, and unsupported schema preservation.
- A third model test was then added for failure before recovery rename (injected disk error), preservation of original/candidate, read-only state, and rejected editing. All **three recovery model tests passed** in a focused rerun: `/tmp/machosts-local-recovery-focused.log`. The final suite contains 124 tests; no second full run was needed for this test-only addition.
- Release build passed `/tmp/machosts-local-recovery-release.log`; Debug build-for-testing passed `/tmp/machosts-local-recovery-debug.log`. Initial sandbox Release failed on the user SwiftPM manifest cache; approved execution passed. An accidentally overlapping Debug invocation hit the shared Xcode build database lock; a sequential rerun passed. No source change was needed for either infrastructure failure. Release deep/strict signature verification passed `/tmp/machosts-local-recovery-signature.log`. AppIntents extraction was skipped because there is no dependency.
- Strict recursive formatting and `git diff --check` passed: `/tmp/machosts-local-recovery-format.log`.
- **Isolated native recovery test could not execute**: `test-without-building -only-testing:MacHostsUITests/LaunchTests/testReviewAndRestoreDamagedLocalWorkspace` failed during runner initialization with “Timed out while enabling automation mode.” Log `/tmp/machosts-local-recovery-ui.log`; result bundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.26_08-57-43-+0100.xcresult`. No test body, app review/cancel/restore interaction, or repeatable startup was verified. No permissions were changed or repeated automation attempts made. The Debug fixture compiled but its runtime acceptance remains open.

No workstation hosts write, metadata change, authorization, privileged operation, or VM integration. Local app-data recovery is implemented with model/build evidence; native sheet/VoiceOver/multiwindow acceptance and production system recovery remain open. Gates 0/4/5 remain open.

## Follow-up – Diagnostic navigation (October 26, 2026)

Profile diagnostics are now native link buttons selecting and focusing the affected complete source line. Targets bind parser-derived UTF-16 positions to the exact source digest; a changed draft rejects the jump. CRLF terminators are excluded. File-wide diagnostics without a parsed line remain explanatory text through disabled links. Remote/read-only text remains selectable without becoming editable. Each view update reuses one parse; the diagnostic list shows at most 20 items with an explicit notice, without truncating source or parser results. Fixing those errors reveals subsequent diagnostics.

Actual verification:

- Full package run passed **125 tests (30 System, 83 Services, 12 Core)**, including the new navigation contract test: `/tmp/machosts-diagnostic-tests.log`. Covers Unicode before/on the target, mixed CRLF/CR/LF, changed-source rejection, unavailable lines, and unsupported bytes.
- Extended native in-process editor probe compiled and passed: `/tmp/machosts-diagnostic-probe-build.log`, `/tmp/machosts-diagnostic-probe.log`. New assertions cover exact selection, first responder, source preservation, redo preservation, and stale jump rejection. Existing scrolling/undo/read-only system rendering checks also passed. Compilation initially encountered the sandbox macro-server restriction; approved compilation passed after retrying a separate formatting/build overlap.
- Release build passed: `/tmp/machosts-diagnostic-release.log`. The sandbox first denied the user manifest cache; approved execution passed. Strict recursive formatting and `git diff --check` passed: `/tmp/machosts-diagnostic-format.log`.
- XCUITest, VoiceOver, diagnostic-link keyboard activation, and full native sheet/multiwindow acceptance were not executed in this increment. The native probe validates the editor bridge, not the SwiftUI diagnostic-button interaction. No new localization keys or dependencies.

No workstation hosts writes or metadata changes, authorization, VM operations, or production writer. Gates 0/4/5 remain open.


## Follow-up – Native workspace commands (October 26, 2026)

The main menu now exposes window-scoped profile creation/save, Find/Replace, cross-profile search, preview, folders, trash, and system status. Shortcuts: Cmd-N, Cmd-S, Cmd-F, Option-Cmd-F, Shift-Cmd-F, and Shift-Cmd-P respectively for creation/save/find/replace/search/preview. Preview remains read-only. Commands use SwiftUI focused scene values and existing workspace actions; sheets remove the command context to prevent background mutations or overlapping sheets. Find requires a selected profile; Replace additionally requires a writable local profile. New/save/preview/folder editing require a writable workspace. No selected profile is required for cross-profile search or workspace inspection.

Find/Replace requests bind to the selected profile identity and use the existing NSTextView/AppKit find bar, including focus transfer from other fields and deferred delivery before window attachment. Each request is consumed once; dismissing the bar is not undone by unrelated view updates. Replace requests reaching a read-only editor are downgraded to Find. Existing native text editing/undo and autosave remain the source of changes. New menu strings have English/German catalog entries.

Actual verification:

- Release build and Debug build-for-testing passed with the cached commands in `docs/DEVELOPMENT.md`: `/tmp/machosts-commands-release.log`, `/tmp/machosts-commands-debug.log`. The initial sandbox Release build failed on the existing user manifest-cache restriction; approved execution passed.
- Extended native in-process editor probe compiled and passed: `/tmp/machosts-commands-probe-build.log`, `/tmp/machosts-commands-probe.log`. New assertions verify native Find/Replace bar presentation, unchanged source/undo, and no reopening after dismissal on an unrelated update. All previous Unicode/CRLF, navigation, undo/redo, large-text, styling, and read-only system rendering assertions also passed. Macro-plugin compilation and native window execution required approved execution outside the coding sandbox. This verifies bar routing/presentation, not user-entered search/replacement or complete menu interaction.
- Strict recursive formatting, command English/German catalog coverage, `git diff --check`, and Release deep/strict signature verification passed: `/tmp/machosts-commands-format.log`, `/tmp/machosts-commands-signature.log`. Package runtime sources were unchanged; the previously evidenced 125-test suite was not repeated for this app-only increment.
- Added isolated `LaunchTests/testWorkspaceMenusRouteSearchAndPreview`, covering keyboard creation, Find after name-field focus, cross-profile search, preview availability, and blocking creation behind a sheet. Debug test compilation passed. **Native execution failed before the test body** while enabling automation mode (runner initialization timeout, exit 65): `/tmp/machosts-commands-ui.log`, result bundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.26_10-10-02-+0100.xcresult`. No app/menu interactions were executed. No permissions were changed and no repeated automation attempts were made.

Full menu/multiwindow/VoiceOver and actual Find/Replace interaction acceptance remain open. No workstation hosts writes/metadata changes, authorization, or VM integration. Gates 0/4/5 remain open.


## Follow-up – Window-local selection and editor undo (October 26, 2026)

Profile selection now belongs to each workspace window. Creating, searching for, duplicating, or restoring a profile selects it only in the initiating window. Removing a selected profile in another window clears only the now-invalid selection. Drafts, autosave, workspace locking, and system observation remain shared. New Window (Shift-Cmd-N) opens another workspace window without copying a selection; New Profile remains Cmd-N. Failed create/duplicate/restore actions preserve the current selection. Read-only sidebar rows remain selectable for inspection; their mutation menus are disabled.

Each native text view now owns its undo manager instead of using the window's shared manager. Programmatic replacements clear only that editor's history, preserving other editors and controls. When another window changes the same draft, the receiving editor synchronizes text and invalidates obsolete undo offsets; the originating editor retains its own valid undo/redo. Switching profiles still creates a fresh editor/undo context; this does not promise persistent undo across profile switches.

Actual verification:

- Extended in-process native editor probe compiled and passed: `/tmp/machosts-windows-probe-build.log`, `/tmp/machosts-windows-probe.log`. Covers distinct managers for two editors in one window, preservation of the second editor's undo after replacing the first draft, two-window synchronization on a shared draft, invalidation of obsolete undo/redo, and preservation of the originating editor's redo. All existing Unicode/CRLF, styling, navigation, Find/Replace bar, 10,000-line scrolling, and read-only rendering assertions also passed. Initial sandbox compilation failed on the known macro-server restriction; approved compilation/execution passed. All draft text was in memory.
- Release build and Debug build-for-testing passed using the cached development commands: `/tmp/machosts-windows-release.log`, `/tmp/machosts-windows-debug.log`. Initial sandbox Release failed on the existing SwiftPM manifest-cache restriction; approved execution passed.
- Strict recursive formatting, `git diff --check`, English/German New Window catalog coverage, and Release deep/strict signature verification passed: `/tmp/machosts-windows-format.log`, `/tmp/machosts-windows-signature.log`.
- Added `LaunchTests/testWindowsKeepIndependentProfileSelections`, covering a second empty-selection window, independent creation/editing, preservation of both selected sources, and shared save. It compiled in Debug. XCUITest execution was not repeated because the previous run failed during automation initialization before its test body. This increment establishes native editor synchronization/undo evidence, not full SwiftUI window/menu/selection or VoiceOver acceptance. Package runtime code was unchanged; the previously evidenced 125-test suite was not repeated.

No workstation hosts writes or metadata changes, system authorization, privileged operation, or VM integration. Gates 0/4/5 remain open.

## Follow-up – Deleted profile review (October 26, 2026)

Trash now offers a window-local, searchable list of deleted profile names and explicit selection before restoration. The review shows deletion date, local/remote kind, and complete read-only source using the existing native editor, with syntax colors, line numbers, selection/copy, and a native Find button. Name filtering is literal and case-insensitive; empty trash and no matches have distinct localized messages. Closing the sheet does not restore or edit anything. Restore uses the existing shared model, returns the profile inactive, selects it only in the initiating window, and closes the sheet only on success. A failed restore keeps the review open with the localized model error. Read-only workspaces permit inspection while disabling restoration. Removal/restoration from another window clears invalid review selection. English/German catalog entries cover new interface text.

Actual verification:

- Full package run passed **127 tests (30 System, 85 Services, 12 Core)**, parameterized cases additional: `/tmp/machosts-trash-tests-final.log`. New private-workspace tests cover persisted remote trash across reopening, exact Unicode/CRLF and invalid-draft preservation, stable identity/kind, missing-folder fallback, inactive restoration, no applied receipt/intent, and successful restore at the combined 500-profile/trash limit after creation is correctly rejected. The first test run failed because the new fixtures used a non-advancing draft revision and exceeded the combined live/trash limit; fixture corrections passed without production-model changes.
- Release build passed: `/tmp/machosts-trash-release.log`; the sandbox initially denied SwiftPM manifest-cache access, and approved execution passed. Debug build-for-testing passed: `/tmp/machosts-trash-debug.log`. Final localization branches are verified by `/tmp/machosts-trash-release-final.log` and `/tmp/machosts-trash-debug-final.log`.
- Strict recursive formatting and `git diff --check` passed: `/tmp/machosts-trash-format.log`. Release deep/strict signature verification passed: `/tmp/machosts-trash-signature.log`.
- New `LaunchTests/testTrashReviewPreservesTextAndRestoresInactive` compiled in Debug. It covers deletion, exact source review, close without restore, name filtering, and inactive restoration. XCUITest execution was not repeated because recent attempts failed during automation initialization before test bodies. Full sheet, native Find interaction, keyboard/VoiceOver, and multiwindow acceptance remain open. The existing editor bridge is reused without changes; no new native editor probe run was required.

No workstation hosts writes or metadata changes, authorization, privileged operation, or VM integration. Gates 0/4/5 remain open.

## Follow-up – Filtered entry controls and atomic bulk changes (October 26, 2026)

Entry switches now support literal case-insensitive filtering of original record text (including aliases and inline comments), enabled/disabled/all state filters, matching counts, and digest-bound source-line navigation. The list displays at most 200 records with an explicit notice; bulk enable/disable uses every matching record, including matches beyond the display cap. The interface explains whole-line scope and all-match scope. Filtering never includes ordinary comments, invalid lines, or reserved markers. Remote/read-only profiles remain inspectable with mutation controls disabled. An incomplete parser result due to byte/line limits disables entry mutations and explains the limit. The collapsed disclosure does not construct the filtered list.

The core bulk operation validates the exact source digest, local profile kind, every requested line, final byte budget, and revision before accepting any mutation. It preserves comments, whitespace, aliases, Unicode, CR/LF/CRLF, and the final unterminated line; unchanged records retain their original bytes. It assembles the result in a single pass rather than repeatedly shifting the source for each replacement. All changed records create one profile/workspace revision and one autosave submission. No-op selections do not create revisions. A stale or partly invalid selection rejects the complete action. Desired profile activation is independent of entry switches; system state is unchanged.

Actual verification:

- Full package run passed **131 tests (30 System, 89 Services, 12 Core)**, with parameterized cases additional: `/tmp/machosts-bulk-tests-final.log`. Four new tests cover literal filtering, Unicode UTF-16 locations, aliases/comments, mixed line endings, exact preservation, ordinary-comment/invalid/missing-line rejection, stale digests, remote kind, no-op revisions, byte/line/revision limits, and all 250 matching entries persisted as one workspace change without applied receipt or intent. The initial run's new persistence test attempted to reopen a still-locked store and failed with `alreadyOpen`; scoping the original store/model lifetime correctly fixed the fixture. No product locking relaxation.
- Release build and Debug build-for-testing passed: `/tmp/machosts-bulk-release.log`, `/tmp/machosts-bulk-debug.log`. Initial sandbox invocations failed on Xcode's user manifest cache; approved execution passed. AppIntents metadata extraction was skipped because there is no framework dependency.
- Strict recursive formatting and `git diff --check` passed: `/tmp/machosts-bulk-format.log`. All 12 new interface strings have English/German catalog entries. Release deep/strict signature verification passed: `/tmp/machosts-bulk-signature.log`.
- Added `LaunchTests/testFilteredEntryBulkActionsPreserveOtherSource`, covering native filtering, bulk disable/enable, source navigation, preserved unrelated source, inactive desired profile, and unapplied state. The new test compiled in Debug. Native execution was not repeated after recent automation-initialization timeouts. Full SwiftUI controls, keyboard/VoiceOver, source navigation button, and multiwindow acceptance remain open. The native editor bridge itself is unchanged; the existing probe was not repeated.

No workstation hosts writes or metadata changes, authorization, privileged operation, or VM integration. Gates 0/4/5 remain open.

## Follow-up – Discoverable profile organization (October 26, 2026)

- The window-scoped Profiles menu now exposes duplicate-as-local, move up/down, and move to trash for the selected profile. Existing sheet suppression disables these actions while a workspace sheet is open. Missing selections and read-only workspaces disable mutations.
- The profile detail view exposes folder assignment and a native Profile actions menu, so organization is available without opening a sidebar context menu. Folder choices use stable IDs and full hierarchy labels.
- Duplication from detail, sidebar, or the main menu selects the new inactive local copy only in the initiating window. This fixes the remote detail action previously leaving the read-only original selected. Existing source/folder preservation and shared autosave remain unchanged.
- Ordering availability follows all persisted siblings, including when cross-profile search hides rows. Boundary actions are disabled in the detail, sidebar, and main menus. Ordering changes neither activation nor system state.

Actual checks:

- Full **132 package tests** passed (30 System, 90 Services, 12 Core), including a new private-workspace contract covering sibling boundaries/overflow, no-op preservation, duplication, folder assignment, deletion, exact CRLF/Unicode source preservation, and durable draft state without applied receipts/intents. Log: `/tmp/machosts-profile-actions-tests.log`.
- Strict recursive formatting and `git diff --check` passed. Log: `/tmp/machosts-profile-actions-format.log`.
- Release build and Debug build-for-testing passed using the cached commands in Development. Xcode initially could not access the user manifest cache inside the sandbox; the approved retry passed. Logs: `/tmp/machosts-profile-actions-release.log`, `/tmp/machosts-profile-actions-debug.log`.
- English/German coverage for the profile action labels and deep strict Release signature verification passed.
- New isolated private-workspace XCUITest compiled. The attempted isolated execution stalled during runner initialization: the log reached “Running tests…” but emitted no suite/test-body output for more than two minutes. The runner and parent xcodebuild were explicitly terminated; this is **not a native pass**. Log: `/tmp/machosts-profile-actions-ui.log`. Full menu/multiwindow/VoiceOver acceptance remains open.

No workstation hosts writes, authorization implementation, or production apply were introduced. Gates 0/4/5 remain open.


## Follow-up – Preview source navigation (October 26, 2026)

Added mappings, conflicting profile mappings, and profile parser diagnostics in the frozen preview now link to their exact source lines. Selecting a link closes the sheet, clears cross-profile search, and selects the profile/UTF-16 line only in the initiating window. Navigation checks both the frozen preview input and current profile source digest. Changed or deleted profiles cannot receive stale jumps. Remote profiles remain read-only. System origins remain informational; removed mappings have no source link because their provenance can describe historical source.

Location indexing runs on the preview service actor, parses each referenced profile once, and indexes only displayed origins under the existing list caps. Unicode and CR/LF/CRLF line offsets use the same diagnostic-location contract as the native editor. The link includes profile/line accessibility text and a localized English/German help label.

Also corrected the native preview input to include `SystemObservationModel.previewRevision`. The service value already supported this field, but the view had omitted it. Restart or transient read failure now invalidates a frozen preview even when equal bytes return before SwiftUI renders an intermediate state.

Actual verification:

- Full **134 package tests** passed (30 System, 92 Services, 12 Core): `/tmp/machosts-preview-links-tests.log`. Two new contracts cover Unicode/mixed-line-ending navigation, invalid source lines, missing/system origins, changed/deleted drafts, conflict and diagnostic indexing. Extended existing tests verify historical removals are not indexed and equal contents with a different observation revision produce different preview input. The final focused rerun passed all nine preview tests: `/tmp/machosts-preview-links-focused.log`. The first compile identified a missing explicit parser context; it was corrected before the passing run.
- Release build and Debug build-for-testing passed: `/tmp/machosts-preview-links-release.log`, `/tmp/machosts-preview-links-debug.log`. Xcode initially could not access its manifest cache in the sandbox; approved execution passed. Final accessibility-label Release/Debug builds also passed: `/tmp/machosts-preview-links-release-final.log`, `/tmp/machosts-preview-links-debug-final.log`.
- Strict recursive formatting and `git diff --check` passed: `/tmp/machosts-preview-links-format.log`.
- English/German coverage for the new help label and deep/strict Release signature verification passed: `/tmp/machosts-preview-links-signature.log`.
- Native sheet dismissal, focus/selection, keyboard/VoiceOver, and multiwindow acceptance remain unexecuted. The existing private XCUITest workspace intentionally has no observed system contents, and recent automation runner initialization remains blocked. No synthetic system observation or successful apply path was added to the app.

No workstation hosts writes or metadata changes, authorization, or production apply. Gates 0/4/5 remain open.


## Follow-up – Local text exchange integration (October 26, 2026)

File-menu/toolbar Import / Export now opens a window-local sheet using the shared
profile model and native editor. Imports are reviewed and inserted inactive with
normal autosave; exports capture the selected draft and explicitly choose original
source or enabled entries. Read-only profiles can be exported. This independent
phase-7 increment and its 139-test package/Release/Debug evidence are recorded in
[phase 7](phase-7.md). Full native file-panel/keyboard/VoiceOver acceptance remains
open; gates 0/4/5/7 remain open.
