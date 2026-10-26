# Phase 0 – Local preparation

Date: October 25, 2026. **Status: local preparation complete; gate 0 not passed / evidence outstanding.** The user explicitly postponed VM tests. [ADR 0002](../decisions/0002-deferred-gate-0.md) now defers gate 0 and permits independent development from phase 1 onward. Reports below describe their historical state; statements that phase 1 had not started or Git was absent apply to those runs, not the current repository.

## Implemented artifacts

[Experiments/AuthorizationProbe](../../Experiments/AuthorizationProbe/README.md) contains a standalone Swift package, native SwiftUI demo, short-lived unprivileged demo tool, local packager, Swift Testing tests. No external packages, developer team, password management, or arbitrary system write path.

The store creates its own private disposable file. It validates request shape/expected digest/ambiguous markers/existing symlink and hardlink targets, creates backup/journal/receipt, and reconstructs injected failures before/after commit. New foreign state blocks automatic overwrite. This is a limited workflow model, not root-suitable filesystem code.

The app can exercise local apply/readback/restore. A separately enabled VM button contains only fixed OS authorization for Apple's `/usr/bin/id -u`; it was **not pressed**. GUI/demo tool reject root by code; actual root launch was not tested.

## Environment

- Apple Silicon/arm64, host macOS 27.0.1, Xcode 27.1 (27A9275), Swift 6.4, SDK 27.0.
- Package deployment target 27.0, Swift 6 language mode.
- UTM at `/Applications/UTM.app`; `utmctl list` exited 134 without output. No `.utm` VM in two checked usual directories; not a complete inventory of user drives.
- Existing filesystem/process sandbox. Module/package caches under writable `/tmp/machosts-phase0-*`, without overriding `$HOME`/`$CODEX_HOME`.

## Initial checks actually passed

| Check | Result |
| --- | --- |
| Debug build, all targets/Swift Testing | Passed; 12 functions including parameterized cases |
| Unknown request fields/operations, digest format, oversize | Rejected as expected |
| Foreign CRLF/UTF-8 comments/missing final LF | Fixture behavior verified |
| Broken/duplicate/reversed markers | Composition rejected |
| Apply/readback/full-backup restore on private fixture | Exact original restored |
| Stale request after apply | Rejected; current content retained |
| No-op without owned block | Succeeded without backup/journal |
| Failure before/after backup, after journal/replacement/receipt | Expected state reconstructed |
| External changes after injected commit interruption | Preserved; further apply blocked |
| Symlink/hardlink test target | Read rejected; referenced file unchanged |
| Release using local native SwiftPM builder | Passed |
| CLI directly/from signed bundle with `--demo` | Passed, exit 0 |
| CLI `--target /private/etc/hosts` | Rejected, expected exit 64; target not opened |
| `swift-format lint --strict` | Passed |
| App/ZIP packaging without account/team | Passed |
| `codesign --verify --deep --strict --verbose=2` | Bundle/embedded binary verified |
| `codesign --display --verbose=4` | arm64, `Signature=adhoc`, flags `adhoc,runtime`, `TeamIdentifier=not set` |
| Embedded demo tool `otool -L` | Only `/usr/lib` and `/System/Library` dependencies in checked artifact |

The 12 functions test the model, not a future privileged writer. Stale-digest rejection is not full replay protection after returning to identical bytes. Injected failures are not actual process crashes/power loss.

### Commands

From repository root. [Reproduction instructions](../../Experiments/AuthorizationProbe/README.md).

```sh
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules swift test --package-path Experiments/AuthorizationProbe --scratch-path /tmp/machosts-phase0-build --cache-path /tmp/machosts-phase0-cache --disable-sandbox
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules swift build --build-system native -c release --package-path Experiments/AuthorizationProbe --cache-path /tmp/machosts-phase0-cache --disable-sandbox
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules Experiments/AuthorizationProbe/.build/arm64-apple-macosx/release/PackageProbe
Experiments/AuthorizationProbe/Output/MacHostsAuthorizationProbe.app/Contents/MacOS/MacHostsProbeTool --demo
codesign --verify --deep --strict --verbose=2 Experiments/AuthorizationProbe/Output/MacHostsAuthorizationProbe.app
xcrun swift-format lint --strict --recursive Experiments/AuthorizationProbe/Sources Experiments/AuthorizationProbe/Tests Experiments/AuthorizationProbe/Package.swift
```

Initial output: `Test run with 12 tests in 0 suites passed`; tool: `PASS: isolated fixture apply, readback and exact restore; no system file accessed.`

## Local download artifact

- App: `Experiments/AuthorizationProbe/Output/MacHostsAuthorizationProbe.app`
- ZIP: `Experiments/AuthorizationProbe/Output/MacHostsAuthorizationProbe.zip`
- Generated ZIP SHA-256: `8bf05473bd9229da1bf952021d32198e2e24ac02537b0bbc0f68a8a5b2fb0c9e`
- Allocated size measured with `du`: app 500 KiB, ZIP 132 KiB. Minimal experiment, not product size forecast.

`Output`/build directories are generated and ignored. No upload/publication. Repackaging changes the digest; packager deliberately refuses to overwrite an existing app. Later follow-ups below did **not** rebuild these artifacts, so that digest belongs to the earlier build.

## Problems found and limits

1. Initial CRLF test failed because Swift splitting on `\n` missed intended CRLF behavior. Marker recognition now uses bytes; all tests then passed.
2. First manifest build wanted an unwritable global Clang cache; local cache paths fixed it.
3. New default SwiftPM builder failed at dSYM with `Operation not permitted`; native builder passed. It is deprecated and only a prototype workaround. User-cache warnings/some `sandbox-exec` messages in the successful build are recorded environment limitations.
4. Initial packager failed inside its binary-path query's extra SwiftPM sandbox. That query now also uses `--disable-sandbox`; packaging/verification then passed. This disables neither SIP nor Gatekeeper.
5. Computer Use was not approved for the new app. No confirmed GUI start/click test/visual QA; no alternate UI-control workaround was used.
6. Initial store used Foundation atomic replacement and preflight `lstat`; TOCTOU/fsync/metadata/restore/multiprocess limits are explicit in its README. Later follow-ups close specified read/schema issues only; none approves root/product reuse.

## Follow-up – Unambiguous request input

October 25, 2026, local phase-0 work only. `ProbeRequest.decode` prevalidates a flat JSON object of at most 16 KiB before typed decoding. It rejects duplicate decoded keys, including Unicode escapes and any ordering, nested values, bad string escapes, trailing data, truncated requests. Field ordering/JSON whitespace remain free. Numeric version allows integer JSON notation only.

Behavior tests cover identical/conflicting duplicates of all four fields before/after originals, escaped duplicate key, valid reordered/escaped keys, invalid envelopes, every truncation boundary. Protection applies to `ProbeRequest.decode`; direct Codable cannot detect duplicate keys. Safe transport/replay/privileged integrity remain open.

Debug all-target build/tests passed: **16 functions**; recursive strict formatting passed, exit 0. Same commands/local caches as above; unwritable user-cache warnings persisted. No Release/signature/GUI/VM rerun, system write, authorization, or phase-1 start. There was no Git repository; changed sources were reviewed directly.

## Not executed / not proven

- Protected root launch/transport of our own Swift binary, including libraries/updates.
- Actual macOS-27 system authorization with cancellation/caching/timeout.
- Process kill/restart and power-loss/durability behavior.
- Real hosts transaction, metadata, DNS-cache operation, exact VM system restore.
- Quarantined first launch, install/update, multiuser behavior in a fresh VM.
- SwiftUI visual/UI acceptance.

The prototype never opened/wrote workstation hosts. No root services installed, authorization requested, or system protections disabled.

## Follow-up – Bounded reads and apply size limit

October 25, 2026. Replaced `Data(contentsOf:)` followed by a limit check with reads of at most 64 KiB per chunk and 1 MiB plus one probe byte total for fixture/backup/journal/receipt. Handles close after read/limit failure; close failure also fails the operation. The historical `lstat`/open gap was still open at this step.

Apply now rejects resulting content over 1 MiB before backup/journal, avoiding an oversized write followed by failed readback from valid limit-sized input. Tests cover empty/chunk boundaries/exact limit/one byte over/double size/append overflow. Rejection preserves fixture and creates no artifacts. Oversized recovery backup preserves target/open journal and blocks applies.

Debug all-target build/tests passed: **20 functions**; strict recursive formatting passed, exit 0. Same cache warnings/local caches; direct source review, no Git yet. No updated Output artifacts, system access, authorization, Release/signature/UI/VM checks. Gate 0 open; phase 1 had not started at this point.

## Follow-up – Validate the opened read object

October 25, 2026. Replaced `lstat` then reopen with `open(O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)` and `fstat` on that descriptor: regular file, one hardlink, current-user owner. Bounded reads use that descriptor; validation/read failures close it and close errors are not swallowed. This supersedes the earlier read-open gap; path-based writing is unchanged.

Two new parameterized functions cover directories/FIFOs/dangling symlinks at fixture path and symlinks/hardlinks on backup/journal/receipt. Recovery/restore rejects them, preserving target/referenced bytes/directory entries; open journals still block apply. Existing limit/link/apply/recovery cases pass.

Debug all-target build/tests passed: **22 functions**; strict recursive formatting passed, exit 0. Same cache warnings/local caches, direct source/test/document review, no Git yet. No deterministic race/multiprocess/fsync/durability proof, protection against swapped parents/concurrent in-place changes, or root approval. Write check/replace gap remains. No updated artifacts or Release/signature/GUI/VM rerun; no hosts access/authorization. Gate 0 open; phase 1 unstarted then.

## Follow-up – Journaled fixture restore

October 25, 2026. `restoreOriginal` previously replaced/read back directly without journal. Apply/restore now share commit: before-backup, journal, revision check, replacement, readback, receipt. Internal operation enum selects fixed artifact names, never request paths. Restore backs up immediate current state to `restore-before.bin`, records `restore-receipt.json`, and preserves original `original.bin`/`receipt.json` bytes. Recovery checks the operation-specific backup and reconstructs before/after outcomes without automatically writing back.

Four new functions include five failure boundaries: before backup, after backup/journal/replacement/receipt. Open restore journal blocks apply/restore. Recovery permits retry; already restored state is artifact-free no-op. Also checked stale digest, unchanged original apply artifacts, distinct restore receipt/new transaction ID, corrupt restore backup, external change after interruption. Corrupt backup/foreign current bytes preserve target/journal.

Debug all-target build/tests passed: **26 functions**; strict recursive formatting passed, exit 0. Same cache warnings, direct source review, no Git. Interruptions remain injected within one session, not kills/restart/multiprocess/fsync/power loss. Path-writer limits remain; no root approval. Internal journal format changed without old-journal migration; prototype never reopens old sessions. No artifact update, Release/signature/GUI/VM rerun, hosts access, authorization. Gate 0 open; phase 1 unstarted then.

## Follow-up – Reject unsafe artifacts before writes

October 25, 2026. Former `fileExists` followed journal symlinks, missing dangling links: apply could replace backup before failing journal write, and recovery falsely reported clean. Presence now uses `lstat`: any journal entry blocks apply/restore; other lookup errors propagate. Recovery validates the object through the descriptor reader.

Shared commit now checks existing fixed backup/receipt destinations for regular type, owner, one hardlink before the first backup write. Previously unsafe receipt detection happened after fixture replacement. Actual changes require this preflight; no-op remains artifact-free.

Two new parameterized functions cover **25 cases**: five unsafe journal types and five file types at four apply/restore artifact paths (dangling symlink, symlink, hardlink, directory, FIFO). Rejection preserves fixture, backup/receipt/reference bytes, entries. Bad journals block and are never treated as clean.

Debug all-target build/tests passed: **28 functions**; formatting passed, exit 0. Same caches/warnings, direct review, no Git. Preflight protects against existing unsafe entries, not concurrent swaps. No root/multiprocess/kill/fsync evidence, artifact update, Release/signature/GUI/VM rerun, hosts access, authorization. Gate 0 open; phase 1 unstarted then.

## Follow-up – Stored transaction consistency

October 25, 2026. A decodable journal/matching backup alone previously sufficed; equal before/after digests could misclassify an unexecuted write as committed and delete the journal. Recovery/restore now validate receipts before mutations: both digests are 64 lowercase hexadecimal characters, differ, and `unchanged` is false. No-op returns an unsaved result. Journal/apply-receipt JSON failures become `recoveryRequired`; type/I/O/size failures remain distinct.

Two parameterized functions cover **18 cases**: bad before/after digest, equal digests, contradictory `unchanged`, truncated JSON, missing digest on apply/restore journals and apply receipt before restore. Rejected recovery preserves all names/bytes/journal and blocks transactions. Invalid apply receipt stops restore without new artifacts. Existing interruption/no-op/restore cases pass.

Debug all-target build/tests passed: **30 functions**; formatting passed, exit 0. Same caches/warnings, direct review, no Git. This is consistency validation, not authenticity/transport proof. At this step extra/duplicate JSON keys remained unguarded; the next step supersedes that limit. No updated artifacts or Release/signature/GUI/VM rerun; no hosts access/authorization. Gate 0 open; phase 1 unstarted then.

## Follow-up – Unambiguous recovery JSON schemas

October 25, 2026. `TransactionJSON` validates fixed journal/receipt schemas before Codable. Decoded-key duplicates, including escapes, extra/missing fields, wrong types, trailing data, and excess nesting become `recoveryRequired`. Bounded descriptor reads precede it; consistency checks remain. Validation happens before writes. This closes the previous extra/duplicate-key limit.

Integration covers apply/restore journals/apply receipt, escaped duplicates, nested/trailing values, duplicate outer `kind`/`receipt`; rejection preserves every name/byte and open-journal block. Two new parameterized functions cover every truncation boundary and valid escaped keys/whitespace. **32 functions** total.

Debug all-target build/tests and strict recursive formatting passed, exit 0; `/tmp/machosts-phase0-latest-test.log`. Same user-cache warnings/local caches, direct review, no Git. No authenticity/immutable-storage/race/multiprocess/durability proof, artifact update, Release/signature/GUI/VM rerun, hosts access, or authorization. Gate 0 open; phase 1 unstarted then.

## Follow-up – Reject files writable by others

October 25, 2026. Owner checks alone did not exclude other-user POSIX write access. Descriptor reads and path-write preflight now reject `mode & 0022 != 0` as `unsafeFile` for fixture/backup/journal/receipt, including restore artifacts. Existing unsafe entries are never accepted by repairing mode with chmod.

Four new parameterized functions cover **18 cases**: fixture modes 0620/0602/0666; group/other write on four output types and apply journal/backup during recovery. Rejection preserves names/bytes/open-journal blocking. Restore backup/receipt input checks covered. Modes 0400/0600/0644 remain readable.

Debug all-target build/tests passed: **36 functions**; strict recursive formatting passed, exit 0; `/tmp/machosts-phase0-latest-test.log`. Same cache warnings/local caches; direct source review, no Git then. Mode-bit checks do not inspect ACLs or close concurrent chmod/path/write/multiprocess/durability gaps. No root approval or new Release/signature/GUI/VM checks; old artifacts unchanged. No hosts access/authorization. Gate 0 open; phase 1 unstarted then.

## Next step

VM postponement ends this local-preparation milestone. Further specify [ADR 0001](../decisions/0001-privileged-write.md)'s candidate and obtain missing evidence in a confirmed disposable VM. Independently continue under ADR 0002; production writer remains blocked. Product direction is already decided; open work is technical proof, not renewed approval of agreed goals.
