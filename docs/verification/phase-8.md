# Phase 8 verification – package performance measurement

November 10, 2026. Independent local work under ADR 0002. **Gate 8 is open.** This
report covers the package benchmark and parser speedups, native launch, idle and memory
measurements with a private measurement build, and in-process typing and scrolling
measurements with the editor fixes they led to. Warm menu, real input latency,
accessibility and the user guide remain open (see "Not done").

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

## Not done

- A prefilter that skipped per-line search was measured and reverted: Foundation's
  case-insensitive search is itself the cost (worst case 130 ms). An exact byte replacement
  would need Unicode case folding (for example "ß" and "ss"). Search runs on its own actor,
  off the main thread.
- Warm menu ≤ 150 ms and real input latency (keyboard events through the window server)
  are unmeasured: they need UI automation, which is still blocked by Accessibility
  authorization. Typing and scrolling were measured in-process only (see above). Idle
  networking with an enabled remote schedule is not measured. VoiceOver, keyboard,
  contrast and motion checks, the failure-matrix rerun and `docs/USER-GUIDE.md` remain
  open.
