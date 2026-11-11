# Phase 8 verification – package performance measurement

November 10, 2026. Independent local work under ADR 0002. **Gate 8 is open.** This
report covers the package benchmark and parser speedups, native launch, idle and memory
measurements with a private measurement build, and in-process typing and scrolling
measurements with the editor fixes they led to, an accessibility tree audit with focus
return after sheets, an editor color contrast audit with the color fix it led to, warm
menu openings, a release inventory with two signing/metadata fixes, backup retention, the first-launch
notice with foreign-entry summary and example profile, and the user guide. Real input latency, VoiceOver listening tests and full
keyboard checks remain open (see "Not done").

## Benchmark

- `Packages/MacHostsKit/Benchmarks/HostsBenchmark` is an executable target. Run it with
  `swift run --package-path Packages/MacHostsKit -c release HostsBenchmark`.
- Synthetic dataset: 100 enabled profiles × 100 lines = 10,000 lines (one comment, nine
  disabled entries, 90 entries with two hostnames and a comment per profile), ten folders,
  538,618 encoded workspace bytes. The editor case is one 10,000-line source (510,620 bytes).
- The system text is an in-memory default-hosts fixture. The store uses a fresh private
  temporary directory that is removed afterwards. No hosts file, network, authorization or
  user workspace is touched.
- Each value is the median of 15 runs, optimized build (`-c release`). Device: Apple M3,
  16 GiB, macOS 27.2 (26B123).

## Results

| Operation | Before | After |
| --- | ---: | ---: |
| Parse all 100 profiles | 89.0 ms | 13.3 ms |
| Validate and encode workspace | 2.6 ms | 2.7 ms |
| Decode workspace JSON | 2.7 ms | 2.7 ms |
| Compose full apply plan (all profiles enabled) | 316.4 ms | 104.7 ms |
| Editor presentation, one 10,000-line source | 99.4 ms | 23.1 ms |
| Search, match in every profile | 94.4 ms | 94.1 ms |
| Search, match in one profile | 94.1 ms | 94.0 ms |
| Durable private draft save | 5.5 ms | 5.4 ms |
| Open private store with saved draft | 7.3 ms | 7.3 ms |
| Open store and workspace model | 7.3 ms | 7.2 ms |

"Before" is the committed parser (`98679f2`) measured with the same benchmark. Store open,
model open and one editor presentation, the package share of first-window work, take
30.3 ms against the 2,000 ms main-window budget (106.7 ms before). This is a lower bound,
not a measurement of the window budget: SwiftUI layout, text system and launch are not included.

The Release `MacHosts.app` built from this tree is 6.1 MiB with an ad-hoc,runtime
signature, within the 40 MiB investigation target.

## Changes

A Time Profiler trace of the benchmark showed parsing dominated by Character-based `split`,
`String.contains`, per-address heap buffers and Character-based hostname validation.

- `parseLine` checks control characters and reserved markers over contiguous UTF-8 bytes
  (`memmem` for the markers). Byte matching also rejects a marker followed by a combining
  mark, which the Character search let through. This rejects strictly more; a test covers that case.
- A byte tokenizer handles lines whose text before the first `#`, and the byte after it, is
  ASCII. Only there are `#`, space and tab whole grapheme clusters, so it is exactly
  equivalent. All other lines use the unchanged Character-based parser.
- Hostname normalization and the strict IPv4 octet check run over bytes. Address
  text still comes from `inet_pton`/`inet_ntop`, now with a stack buffer.

## Equivalence evidence

`ParserEquivalenceTests` (4 tests) compares, with a fixed-seed generator:

- the byte tokenizer against the Character-based parser on a corpus plus 20,000 random lines
  from grapheme-edge fragments (combining marks after `#`, space and tab; NBSP, ideographic
  space and ZWJ; IPv4/IPv6 forms), for enabled and disabled lines;
- byte hostname normalization against the previous implementation on 20,000 names;
- the stack-buffer address parser against the previous implementation on 20,000 literals.

A mutation check removed the "byte after `#` is ASCII" condition, and the comparison failed
with 43 mismatches; the code was then restored.

## Checks

- Full package run: 180 tests passed (30 System, 134 Services, 16 Core) in one run after formatting.
- `xcrun swift-format lint --strict` over the documented paths passed.
- Release build succeeded; `codesign` shows `adhoc,runtime`.

## Native launch, idle CPU and memory (measurement build)

Measured November 10, 2026 on the same device. Launching the shipping Release app would
open the real user workspace, so these values come from a separately compiled Release
variant with the `MACHOSTS_MEASUREMENT` compilation condition (see
[Development](../DEVELOPMENT.md)). It is built with the same optimization and signing settings.
With `--measurement-workspace` it opens a fresh private temporary workspace seeded with
the benchmark dataset above (100 enabled profiles, 10,000 lines, ten folders) or an empty
one. It applies nothing, starts no system observation, remote refresh or schedule, and
shows the private-workspace marker. The shipping Release binary contains neither switch
string (`strings` count 0); the measurement binary contains it.

| Measurement | Result | Budget |
| --- | ---: | ---: |
| First window ready, 100 profiles, six consecutive launches | 669–684 ms, median 678 ms | ≤ 2,000 ms |
| Idle CPU, 100 profiles, 60 s starting 10 s after ready | 0.02 s CPU = 0.03 % of one core | < 1 % |
| Idle CPU, empty workspace, same window | 0.19 s CPU = 0.32 % of one core | < 1 % |
| Resident memory after 70 s, empty workspace | 141.8 MiB RSS, 54 MB physical footprint | ≤ 150 MiB (target) |
| Resident memory after 70 s, 100 profiles | 148.0 MiB RSS, 61 MB physical footprint | — |

- "First window ready" runs from the kernel process start time (`sysctl` `p_starttime`,
  so exec and dyld are included) until two main-queue turns after the loaded workspace is
  published to SwiftUI. It approximates the first rendered frame and does not prove the
  window accepts input. A window listing (`CGWindowListCopyWindowInfo`) showed one
  1050 × 740 on-screen window for the launching process.
- CPU time is the `ps` cumulative time difference; RSS is `ps` resident size and includes
  shared system framework pages, so the `footprint` value is the app-attributable figure.
  Empty-editor RSS is within the 150 MiB investigation target, but with little margin.
- The app was started directly from the shell, outside the coding sandbox (the sandbox
  blocks the window-server connection), and stopped with SIGTERM. Each run used its own
  `machosts-measure-*` directory, and these were removed afterwards.
- Launching with `-ApplePersistenceIgnoreState YES` opened no window in five of five
  launches (0.19 s CPU, no workspace loaded); without the flag, every launch opened its
  window. Normal launches do not pass this flag, so it is a test-launch artifact. Because of
  it, these runs used normal window-state saving for `de.machosts.app`.

## Typing and scrolling in a 10,000-line profile (measurement build)

Measured November 10, 2026 on the same device with `--measurement-interaction` (see
[Development](../DEVELOPMENT.md)): the benchmark workspace plus one enabled
10,000-line profile (about 510 KB). The probe types 300 characters into the middle of the
large profile's real `NSTextView` in 15 bursts of 20 at 30 characters per second, with a
500 ms pause after each burst so debounced styling and autosave run. It then scrolls the
whole document in 120-point steps and makes 60 jumps. "Per event" is the synchronous time
for `insertText` or the scroll call plus `displayIfNeeded`. "Main-thread stall" is the
longest wait of a main-queue block that a background timer enqueues every 5 ms during the
phase, so it also includes debounced styling, parsing and autosave work.

The first run did not finish: it used 39 s of CPU in 40 s and never completed typing.
Sampling found four causes, fixed in this order:

| Change | Typing per event (median) | Stalls > 50 ms |
| --- | ---: | ---: |
| Before: did not finish (each keystroke spent seconds comparing `Profile` values) | — | — |
| Editor hands the model a native string, not the bridged `NSTextView.string` | 62.9 ms | 1,460 |
| Faster native copy (`getBytes`, 0.7 ms instead of 12.7 ms) and detail parsing off the main thread | 27.3 ms | 168 |
| Sidebar rows take plain values and are `Equatable`, so typing does not re-evaluate them | 19.1 ms | 160 |
| Incremental workspace budget bound instead of a full JSON encode per keystroke; syntax colors only near the viewport | 14.7 ms | 0 |

Final result, three consecutive runs:

| Phase | Per event, median / p95 / max | Longest main-thread stall | Stalls > 50 ms |
| --- | ---: | ---: | ---: |
| Typing, 300 characters | 14.7–14.8 / 18.1–20.6 / 29.5–33.4 ms | 43.0–47.1 ms | 0 |
| Scrolling, 1,331 steps | 0.14–0.15 / 0.26–0.34 / 0.52–0.84 ms | 21.4–25.1 ms | 0 |
| Jumps, 60 | 0.78–0.91 / 0.94–1.23 / 1.05–1.28 ms | 9.7–11.9 ms | 0 |

All 300 characters were accepted and saved (`saved=true accepted=300`). What remains per
keystroke is mostly SwiftUI's own window layout pass. "No perceptible stalls" has no
numeric threshold in the product outline; these runs had no main-thread stall over 50 ms,
but this is a synthetic in-process probe, not human or XCUITest acceptance. Scroll times
are the synchronous AppKit display calls, not compositor frame times.

Details of the changes:

- `NSTextView.string` returns a Foundation-backed String. Comparing it with a stored
  500 KB source fell back to slow Unicode comparison in every SwiftUI and model equality
  check. The editor coordinator now keeps a native UTF-8 copy and compares against it.
- The profile detail view parses for diagnostics and entry switches in a detached task,
  debounced by 150 ms, instead of in `body`. A newly selected profile is parsed once
  synchronously. Diagnostic jumps and entry switches remain digest-bound, so a result that
  trails the text is rejected instead of being applied to newer text. A diagnostic's
  source location is now computed on click.
- `ProfileWorkspaceModel` keeps a proven upper bound on the encoded workspace size for
  pure source edits. It starts from the last exact encoding and adds six bytes per UTF-8
  byte of each edited source (the largest JSON escape) minus its original bytes, plus
  revision-digit slack. Every other change, and any edit whose bound exceeds the 32 MiB
  budget, still encodes exactly. New tests check the bound against the exact encoding
  over 400 random edits with every escape class (a mutation to a 1× factor failed with
  247 issues), and that an edit escaping beyond the budget is still rejected.
- Syntax colors are applied to the visible text plus one screen above and below, and to
  further text as it scrolls into view (on the next main-queue turn, so styling never
  forces glyph layout during AppKit tiling). The native editor probe now checks colors on
  text scrolled into view; without the scroll observer, that check fails.

Checks for this increment: full package run with 182 tests passed (30 System, 136
Services, 16 Core); strict `swift-format lint` passed; the native editor probe passed
all three groups; Release and Debug build-for-testing succeeded; Release is 6.2 MiB with an
`adhoc,runtime` signature, and contains no measurement or UI-test switch strings; all 282
catalog strings have German translations.

Launch was rechecked in eight alternating launches of the previous and the new
measurement build: median 633 ms before, 610 ms after (no regression).

## Idle with read-only system observation

Same build with `--measurement-observe-system` and the 100-profile dataset: 0.02 s CPU
over 60 s starting 10 s after ready (0.03 % of one core), 148.2 MiB RSS and 63 MB physical
footprint at the end. `lsof` showed the process holding `/private/etc` and
`/private/etc/hosts` open read-only, and no network sockets at either end of the minute
(`lsof -i` found none). The measurement build has no remote refresh or schedule, so this
shows no periodic networking from observation; the shipping app's opt-in remote schedule
is not covered.

## Accessibility tree audit (measurement build)

`--measurement-accessibility` walks the app's accessibility tree through the public AX
client API (`AXUIElementCreateApplication` on the app's own process ID), the same tree
VoiceOver reads. In-process queries need no Accessibility permission
(`AXIsProcessTrusted()` was false). AppKit's own `accessibilityChildren` returned only
eight elements, because SwiftUI builds its accessibility nodes only once an assistive
client asks. The walk therefore repeats until the element count is stable twice in a
row, with 500 ms between walks.

Surfaces: the main window with the first of the 100 seeded profiles selected, and the
preview, add-remote and status sheets, opened through the normal window requests. An
interactive element (button, check box, pop-up, menu button, text field, text area,
disclosure, link, row) counts as unnamed when it has no title, description, placeholder
or title element, and no descendant text within four levels. Window and scroll bar
controls are named by the system through their subrole and are excluded. Each sheet is
then closed with a synthesized Escape key event.

| Language | Surface | Elements | Interactive | Unnamed | Esc closes |
| --- | --- | ---: | ---: | ---: | --- |
| English | main | 496 | 136 | 0 | – |
| English | preview | 506 | 139 | 0 | yes |
| English | add remote | 504 | 140 | 0 | yes |
| English | status | 504 | 139 | 0 | yes |
| German | main | 496 | 136 | 0 | – |
| German | preview | 506 | 139 | 0 | yes |
| German | add remote | 504 | 140 | 0 | yes |
| German | status | 503 | 139 | 0 | yes |

The 136 interactive elements are 111 sidebar rows, 17 buttons, 2 text fields, 2 pop-ups,
a menu button, a check box, the editor text area and the entry-switch disclosure. Spoken
names were listed and reviewed in both languages, for example "Search all profiles" /
"Alle Profile durchsuchen", "Desired active" / "Gewünscht aktiv", "Profile source" /
"Profilquelltext". Each sheet adds its own named controls (for example "HTTPS address",
"Add and download", "Cancel"). At the default window width, Import/Export, Folders,
Search and Trash sit in the toolbar's named overflow menu; the File and Profiles menus
also offer them.

The first, AppKit-only walk flagged the window buttons and scroll arrows. A second walk
with the AX client flagged 111 rows that are named by their cell text. Both were false
positives of the rule and were excluded as described above. No code change was needed.

### Focus return after sheets

The first run was started from a background shell, which macOS did not activate, so the
main window was not key after Escape. The audit now starts through `open -n --stderr`,
which activates the app normally. Before each sheet it makes the profile editor the first
responder, as when a shortcut opens the sheet while typing, and compares the first
responder before opening and after Escape:

| Language | Sheet | Esc closes | Main window key | Responder before → after |
| --- | --- | --- | --- | --- |
| English | preview | yes | yes | editor → editor |
| English | add remote | yes | yes | editor → editor |
| English | status | yes | yes | editor → editor |
| German | preview | yes | yes | editor → editor |
| German | add remote | yes | yes | editor → editor |
| German | status | yes | yes | editor → editor |

The sheets are opened through the app's window requests and closed with a synthesized
Escape event sent through `NSApp.sendEvent`, not through the window server. Opening them
from the toolbar or a menu was not exercised. The app contains no custom animations (no
`withAnimation`, `.animation` or transitions), so Reduce Motion has nothing extra to
suppress. Reduce Transparency was not measured.

## Editor color contrast (measurement build)

`--measurement-contrast` resolves the editor's text colors in the light and dark
appearance, composites translucent colors over their background, and reports WCAG 2
contrast ratios for every syntax style on the text background and on the managed-block
highlight (system file view), plus line numbers on the ruler. The editor uses the 13-point
system monospaced font, so the AA target is 4.5:1.

The first run with the system colors found five failures:

| Appearance | Color | On text | On highlight |
| --- | --- | ---: | ---: |
| light | addresses (system blue) | 3.52 | – |
| light | comments, disabled, line numbers (secondary label) | 3.95 | – |
| light | invalid (system red) | 3.57 | – |
| dark | addresses (system blue) | 5.16 | 4.49 |
| dark | invalid (system red) | 4.86 | 4.23 |

`EditorPalette` in `NativeProfileEditor.swift` now replaces those with nearby fixed colors
in the affected appearance. The dark secondary label passed and stays a system color, so
it keeps following Increase Contrast; the replaced colors do not change with that setting.
Result after the fix: lowest ratio 4.97:1 in light (gray on the highlight) and 5.44:1 in
dark; addresses 6.27:1 (light) and 6.60:1 (dark) on the text background. The native
editor probe was updated to expect the palette colors and passed; its light and dark
renderings were checked visually. Errors stay marked by an underline as well as by color.
SwiftUI views outside the editor use system styles only and were not measured.

## Warm menu (measurement build)

`--measurement-menu` opens the menu bar extra eleven times through its status item
button (`performClick`) with the 100-profile dataset. It reports the time from the click
until the menu's tracking loop first runs, which happens after the menu window is ordered
in; each menu stays open 200 ms and must end tracking before the next opening, one second
apart. All 33 openings in three runs succeeded, each with 17 items.

| Run | Cold (first) | Warm median | Warm max |
| --- | ---: | ---: | ---: |
| 1 | 67.5 ms | 22.8 ms | 24.7 ms |
| 2 | 69.8 ms | 22.1 ms | 29.9 ms |
| 3 | 73.5 ms | 22.1 ms | 29.0 ms |

Warm openings stay well within the 150 ms budget. Limits: the click is synthesized in the
process rather than coming through the window server, the time ends at the first tracking
loop turn rather than at a verified frame on screen, and the 100-item
"Desired activation (draft)" submenu was not opened. A first version that cancelled each
menu immediately in its first tracking turn stopped opening menus after two to four
openings; waiting for the end of tracking fixed the measurement.

## Release inventory

November 11, 2026, from the sources and a clean Release build (Xcode 27.1, macOS 27.2).

**Dependencies and licenses.** The package has no external dependencies (no
`Package.resolved`, only a local package reference in the project) and the repository
vendors no third-party code. The only license file is the project's MIT `LICENSE`. The
app links only system frameworks and the system Swift runtime (`otool -L`: Foundation,
AppKit, SwiftUI, CoreGraphics, CryptoKit, ServiceManagement and `/usr/lib/swift`
libraries); the helper tool links Foundation, CryptoKit and the Swift runtime. The
Release app is 6.2 MiB.

**Signatures and entitlements.** The app and the embedded `MacHostsApply` tool are
ad-hoc signed with the hardened runtime (`flags=0x10002(adhoc,runtime)`), without App
Sandbox and without a team. The inventory found that Xcode's injected base entitlements
gave both Release binaries `com.apple.security.get-task-allow`, which lets debuggers and
other same-user processes get the task port. Release now sets
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. After a clean Release build neither binary
carries it; Debug keeps it. The tool still carries Xcode's
`com.apple.application-identifier` (`de.machosts.tool`) and a linker-derived signing
identifier (`MacHostsApply-<hash>`). The authorization path that would rely on the
tool's designated requirement is gated by phase 0 and will have to set a stable identifier.

**Info.plist.** The copyright was written as `\u00a9` in the old-style project file,
which only understands `\U`, so the app showed "Copyright u00a9 2026". It now contains
the © character. No privacy usage descriptions are present, and none are needed: the app
requests no protected resources.

**Logging.** The app, tool and package sources contain no `Logger`, `os_log`, `NSLog` or
`print` calls (`rg`), so no profile names, hosts, addresses or URLs reach the unified log
from our code. Errors are shown in the interface. Diagnostics are a redacted report that
leaves the app only when the user chooses **Copy report** (clipboard).

**Network.** `RemoteProfileFetcher` is the only network code: an ephemeral
`URLSession` without cookie storage or URL cache, HTTPS only, bounded time and size.
Downloads start only for remote profiles the user added, through **Refresh** or the two
settings **Refresh when MacHosts starts** and **Refresh while running**, both off by
default. Without remote profiles the app makes no requests; the idle measurements
above found no sockets. Offline operation was not exercised by disconnecting the
network, which would change system settings.

**Stored data and retention.** User defaults hold only `showsMenuBarExtra`,
`refreshRemoteOnLaunch` and `remoteRefreshHours`. All profile data stays in the
workspace folder described in the [user guide](../USER-GUIDE.md). Backups, recovery
archives and `workspace.previous.json` are never deleted automatically.

**Backup retention (November 11).** Each replacement backup can reach the 32 MiB
workspace limit, so the series is now bounded: after a new `workspace.backup-*.json`
is published, `WorkspaceStore` removes the oldest beyond the 20 most recent
(`backupRetention`). The just-written backup is always kept, even if the clock moved
backwards and its name sorts oldest. Removal opens the name with `O_NOFOLLOW` and
unlinks only a private, user-owned regular file with one link; recovery copies of
damaged snapshots and `workspace.previous.json` are not candidates. Pruning errors do
not fail the backup; extra files remain and are retried after the next backup. Two
new contract tests cover the newest-20 rule, a backwards clock, preservation of the
previous snapshot, and refusal to unlink a hard-linked (shared) backup. Full 184-test
package run, strict lint and Release build passed.

## First launch: notice, foreign entries and example profile (November 11)

The product outline's first-launch workflow asks for a short explanation, an example
profile only on explicit request and a view of hosts entries that something else already
manages. The empty detail view (no profile selected) now says that applied entries
affect the whole Mac and every user, stay in effect after quitting and always need a
preview and administrator approval. It promises no password prompt, and this build still cannot apply.

- `ForeignEntrySummary` (HostsCore) counts active entries outside the managed block and
  their hostnames. The macOS defaults (`127.0.0.1 localhost`, `255.255.255.255
  broadcasthost`, `::1 localhost`) are counted separately. `SystemFileContents.foreign`
  is nil when the file could not be parsed completely (encoding, size or line limit), so no
  partial count is shown. With malformed markers, every entry counts as foreign.
- **Create example profile** calls `ProfileWorkspaceModel.createExample`, which adds one
  inactive local profile from `ExampleProfile.source`. It uses documentation addresses only
  (RFC 5737/3849) and `.example` names (RFC 2606), with one disabled line. Localized heading
  and note text containing a line break is rejected.
- Two new tests: `foreignSummarySeparatesDefaultsManagedBlockAndOtherEntries`
  (defaults, commented lines, a default address with an extra hostname, managed block,
  IPv6, malformed markers, nil past the line limit and for unsupported encoding) and
  `exampleProfileIsInactiveValidAndUsesDocumentationAddresses` (no diagnostics, enabled
  pattern, documentation ranges, German text, nothing applied).
- Native check, measurement build: `--measurement-workspace --measurement-empty-workspace
  --measurement-observe-system --measurement-accessibility`, English and German. The audit
  now also reports the `foreignEntrySummary` text. The main surface had 12 interactive
  elements, none unnamed, including "Create example profile" / "Beispielprofil erstellen".
  The summary read "The system file contains no entries besides the macOS defaults." / "Die
  Systemdatei enthält außer den macOS-Standardeinträgen keine Einträge." It agreed with a
  read-only count of the workstation file (three non-comment lines). The file was only read.
  Clicking the example button natively was not driven; the model test covers creation.
- Full 186-test package run (30 + 140 + 16), strict lint, shipping Release build
  (signature verified, no measurement strings) and measurement build passed.

## User guide

[`docs/USER-GUIDE.md`](../USER-GUIDE.md) covers first launch, profiles and the editor,
activation, preview and conflicts, system status and external changes, remote profiles,
import/export and backups, menu bar and settings, TLS and resolver limits, storage,
migration and recovery, complete removal, shortcuts and limits. It states at the top that
this build cannot change the system file. File names, limits, redirect rules,
diagnostics content and labels were checked against the code.

## Not done

- A prefilter that skipped per-line search was measured and reverted: Foundation's
  case-insensitive search is itself the cost (worst case 130 ms). An exact byte replacement
  would need Unicode case folding (for example "ß" and "ss"). Search runs on its own actor,
  off the main thread.
- Real input latency (keyboard and mouse events through the window server) is
  unmeasured: it needs UI automation, which is still blocked by Accessibility
  authorization. Typing, scrolling, menu openings and sheet dismissal were driven
  in-process only (see above). Idle networking with an enabled remote schedule is not
  measured. Listening tests with VoiceOver, full keyboard navigation, Reduce Transparency,
  contrast of SwiftUI views outside the editor, the failure-matrix rerun, an offline run
  with the network disconnected remain open. Recovery copies of damaged snapshots are
  kept without limit by design.
  The user guide documents the planned apply and removal flows as not yet available; it
  must be updated when the system writer lands.
