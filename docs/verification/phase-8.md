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

## Not done

- A prefilter that skipped per-line search was measured and reverted: Foundation's
  case-insensitive search is itself the cost (worst case 130 ms). An exact byte replacement
  would need Unicode case folding (for example "ß" and "ss"). Search runs on its own actor,
  off the main thread.
- Native budgets (main window ≤ 2 s, warm menu ≤ 150 ms, typing and scrolling, idle CPU
  < 1 % over 60 s, empty-editor RSS) are unmeasured. Launching the Release app would open the
  real user workspace and observe the system file, so it needs a private measurement mode or
  a disposable account. VoiceOver, keyboard, contrast and motion checks, the failure-matrix
  rerun and `docs/USER-GUIDE.md` remain open.
