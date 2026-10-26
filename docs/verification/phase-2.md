# Phase 2 – Parser and pure domain logic

As of October 25, 2026. **Implemented and locally verified; gate 2 passed.** Formal phase-1 clean-checkout/CI items remain open. ADR 0002 permits independent development; gate 0 remains deferred.

## Result and format decisions

`HostsCore` contains a UTF-8 parser retaining original byte ranges and LF/CRLF/CR endings, system IP normalization, ASCII hostname checks, profiles/folders/trash, and revision/digest-bound entry switches. Unicode comments survive. Diagnostics cover unsupported encoding/BOM, controls, invalid addresses, zone IDs, leading IPv4 zeros, reserved markers. One final DNS root dot is removed for conflicts; labels are 1–63 bytes, names excluding that dot at most 253 bytes. Local single names and ASCII Punycode are allowed.

Composition follows profile/source order, deduplicates canonical address/domain pairs, and preserves all entry provenance. Same-family multiple addresses block apply, including conflicts with foreign system entries. IPv4/IPv6 for one domain are allowed. Disabled profiles are excluded; invalid lines in active profiles block. Remote entry switches are read-only.

`ApplyPlan` freezes workspace/source digests, system digest, active IDs, before/after bytes, block operation, added/removed mappings. Workspace digest detects changes even if a caller forgets to increment revision. Expected managed-block digest supports later rejection of external changes. This logic performs no file access/write.

Prefix/suffix remain byte-identical. Only whole-line markers count; duplicate, reversed, nested, or missing markers block. Embedded/other MacHosts markers are rejected; SwitchHosts comments remain foreign. Only digest-bound `ManagedSeparatorEvidence` permits removal of an LF inserted during append. Without evidence the LF remains. Later persistence must associate it with confirmed system state. Existing end-marker terminators survive; new inner block lines use LF.

## Actual verification

Apple Silicon, Xcode 27.1 / Swift 6.4, macOS SDK 27.0. Commands/cache paths: [Development](../DEVELOPMENT.md).

- `swift test` passed: 12 Core functions plus writer-availability test, parameterized format/failure cases, and 100 deterministic generated foreign-region fixtures; `/tmp/machosts-phase2-swift-test.log`.
- Strict recursive formatting passed; `/tmp/machosts-phase2-format.log`.
- Incremental app/tool Release build passed; `/tmp/machosts-phase2-build.log`. Manifest cache access required execution outside the coding sandbox.
- Checked lossless roundtrip, missing final newline, BOM/invalid UTF-8, limits, markers, aliases, normalization, stale-digest toggling, remote read-only behavior, deterministic composition/no-op, foreign conflicts, complete provenance, preview differences, external block digest, exact removal.

Initial Darwin-parser deviations (leading zeros, zone IDs) and BOM-decoder behavior were explicitly handled; final run passed. Two Swift compiler issues (throwing short-circuit expression, complex test macro expression) were also fixed.

No UI acceptance/performance measurement, system hosts access, authorization, or privileged integration. The next independent block at this milestone was phase 3: persistent workspace snapshots/unprivileged recovery.
