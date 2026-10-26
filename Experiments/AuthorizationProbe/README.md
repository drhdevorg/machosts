# Authorization Probe – Phase 0

Unprivileged feasibility prototype, **not the finished MacHosts app** or an approved privileged write path. Deployment target macOS 27.0, Swift 6 language mode, our own Swift targets without external dependencies.

## Included

- Native SwiftUI UI with a complete local file test.
- Short-lived CLI accepting only `--demo`, without arbitrary destination. Root execution is rejected.
- Request with version, UUID, expected SHA-256, and one of two fixed sample operations. Extra fields, duplicate keys (including Unicode escapes), unknown operations, invalid digests, oversize rejected.
- Private disposable file, before-copy, journal, receipt, reconstruction of injected interruptions. Foreign changes are never automatically undone.
- Optional OS-dialog test with fixed AppleScript `do shell script "/usr/bin/id -u" with administrator privileges`. Launches only Apple's `id`, writes no file, disabled without explicit VM-test argument.
- Swift app/ZIP packager with local ad-hoc signing/Hardened Runtime; no account/team configuration.

## Run

From repository root in a normal unprivileged shell:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules swift test --package-path Experiments/AuthorizationProbe --scratch-path /tmp/machosts-phase0-build --cache-path /tmp/machosts-phase0-cache --disable-sandbox
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules swift build --build-system native -c release --package-path Experiments/AuthorizationProbe --cache-path /tmp/machosts-phase0-cache --disable-sandbox
Experiments/AuthorizationProbe/.build/arm64-apple-macosx/release/MacHostsProbeTool --demo
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules Experiments/AuthorizationProbe/.build/arm64-apple-macosx/release/PackageProbe
```

Find the binary directory with `swift build --build-system native -c release --package-path Experiments/AuthorizationProbe --show-bin-path`. The existing native SwiftPM builder was a local workaround: the new default builder failed at dSYM inside the execution sandbox. Native builder is itself deprecated, not a permanent product build standard. `--disable-sandbox` disables only SwiftPM's extra manifest/plugin sandbox within the existing execution environment, not SIP, Gatekeeper, or macOS security features.

Packager creates `Output/MacHostsAuthorizationProbe.app` and `.zip`; existing app artifacts are not overwritten. Deliberately rename/remove the old generated artifact before repackaging. The app never invokes its embedded demo binary as root.

Formatting:

```sh
xcrun swift-format lint --strict --recursive Experiments/AuthorizationProbe/Sources Experiments/AuthorizationProbe/Tests Experiments/AuthorizationProbe/Package.swift
```

## VM test only

First start without extra arguments and run the local test; then separately in the disposable VM:

```sh
open MacHostsAuthorizationProbe.app --args --enable-vm-auth-probe
```

The argument is an interaction barrier, not technical proof of a VM. User/tester must confirm the VM beforehand. Deliberately start the system dialog in the UI; record success/cancellation separately, never passwords. This can prove authorization of Apple's `id` at most, not safe launch of our Swift tool.

## Limits

Fixture/backup/journal/receipt reads are chunk-bounded: stop above 1 MiB after at most limit plus one probe byte. Planned target content over 1 MiB fails before backup/write. Tests cover limits, unchanged rejection state, open journal preservation with oversized recovery backup. This is no total-process-memory measurement.

Reads use `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`, then `fstat` on the opened descriptor for type/link count/owner. Final-component symlinks are not followed; FIFOs do not block on open; nonregular files fail before reading. Handles close after validation/read failures. Tests cover directories, FIFOs, dangling symlinks, symlink/hardlink targets, linked recovery artifacts. This pins the read inode, not immutable content under concurrent in-place writes or trusted parents.

The store is for unprivileged tests only: no fsync/power-loss guarantee, safe descriptor-based root path resolution, general ACL/xattr preservation, multiprocess lock, durable replay database, or actual process-kill tests. Decode wire bytes with `ProbeRequest.decode`; its bounded flat-object check detects duplicates before typed decoding. Direct `JSONDecoder.decode(ProbeRequest.self, …)` lacks this protection. This proves neither transport integrity nor digest binding.

Restore also performs backup/journal/replacement/readback/receipt. Journal operation enum selects fixed internal artifact names. Restore saves current bytes in `restore-before.bin` and `restore-receipt.json`, preserving `original.bin`/original apply receipt. Recovery uses each operation's before/after digests. Tests cover five interruption points, retry after recovery, no-op, stale preview, corrupt restore backup, external change. Interruptions are injected in one session, not restart/durability evidence. Internal journal format changed without migration; old sessions are never reopened.

The write check/replace gap remains. Reader validation does not fully defend against concurrent same-user processes, parent swaps, metadata changes, or writes. Executable demos therefore reject root. Reassess all store components before any privileged product reuse.

Journal presence uses `lstat`; even a dangling journal symlink blocks apply/restore and is rejected by recovery rather than treated as clean. Before the first write, commit checks existing fixed backup/receipt destinations for regular type, current owner, one hardlink. Tests cover symlinks/dangling links/hardlinks/directories/FIFOs; reject unsafe entries before fixture/backup changes. This preflight does not exclude subsequent races. No-op creates no artifacts.

Appending to a file without final LF leaves the required separator LF when the block is later removed; full backup alone restores exact original bytes in this experiment. The product must durably track separator provenance if it removes that LF too.

Stored transactions also require canonical SHA-256 digests, distinct before/after digests, and no saved no-op. Invalid JSON becomes `recoveryRequired`; invalid journal preserves all artifacts and blocks transactions. This is not authenticity. Fixed schemas are checked before Codable for extra/missing/duplicate decoded keys including escapes, wrong value types, and nesting. Invalid data stops writes; tests cover unchanged rejection, valid escaped keys, every truncation boundary. Latest Debug suite: **36 functions**. Existing Output artifacts remain from the earlier packaging run.

Reads/write preflight reject regular files with POSIX group/other write (`mode & 0022 != 0`) as `unsafeFile`, for fixture and artifacts. Existing unsafe entries are not repaired with chmod. Tests check unchanged bytes/names on apply/restore rejection and retained recovery journals. Modes 0400/0600/0644 remain readable. ACLs/concurrent mode changes are not covered; private parents remain an experiment prerequisite.

The prototype never accesses system hosts. Gate 0 remains open until protected tool launch, request transport, and actual VM integration are proven. See [ADR 0001](../../docs/decisions/0001-privileged-write.md) and [phase report](../../docs/verification/phase-0.md).
