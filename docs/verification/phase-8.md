# Phase 8 verification – package performance measurement

November 10, 2026. Independent local work under ADR 0002. **Gate 8 is open.** This
increment measures the package-level work behind the provisional Release budgets and removes
the parser hot spots it found. It does not measure native window, menu, typing, idle-CPU or
RSS budgets; those require launching the app and remain open.

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

## Not done

- A prefilter that skipped per-line search was measured and reverted: Foundation's
  case-insensitive search is itself the cost (worst case 130 ms). An exact byte replacement
  would need Unicode case folding (for example "ß" and "ss"). Search runs on its own actor,
  off the main thread.
- Warm menu ≤ 150 ms, typing and scrolling stalls, and interaction latency of the first
  window are unmeasured: they need UI automation, which is still blocked by
  Accessibility authorization. Idle CPU was measured without system observation; idle
  behavior with observation running, and the absence of periodic networking, still need a
  separate check. VoiceOver, keyboard, contrast and motion checks, the failure-matrix
  rerun and `docs/USER-GUIDE.md` remain open.
