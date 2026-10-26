# Phase 7 – Local exchange (partial completion)

October 26, 2026. Independent local work under ADR 0002. **Gate 7 is open.**
The `.hosts` text exchange and version-1 MacHosts JSON append/export increments are
implemented. Remote profiles, SwitchHosts imports, replacement imports, and their
acceptance matrices remain open. Gates 0/4/5 remain open; this increment neither applies nor authorizes
system changes.

## Implemented behavior

- File menu and workspace toolbar open a window-local Import / Export sheet. Other
  workspace commands are suppressed while it is open. German/English catalog text.
- Import uses a native single-file panel, reads a regular file on the service actor,
  and bounds actual reads to 1 MiB plus one detection byte. Directories/nonregular
  files fail; cancellation is checked between chunks. UTF-8 without BOM is required.
  More than 50,000 lines is rejected, never silently imported in part.
- The complete captured source is reviewable in the read-only native editor, with
  parser styling and up to 20 explicit diagnostics plus a truncation notice. Invalid
  syntax can be imported as an editable draft; no normalization or auto-repair.
- Explicit confirmation inserts that snapshot as one new inactive local profile with
  a fresh ID and one draft revision. Same-name profiles can coexist. Existing
  profiles, trash, activation, receipts and apply intents are preserved. Name and
  complete workspace budgets are validated atomically; failure preserves review.
  Import selects the profile only in the initiating window and uses normal autosave.
- Export uses the profile captured when the sheet opened, including read-only/remote
  drafts. Original-source mode preserves every UTF-8 byte, including invalid or
  disabled lines. Enabled-entry mode rejects all parser diagnostics and emits only
  enabled records, retaining spelling, aliases, comments and original line endings.
  Profile activation does not filter individual source records in this mode.
- Native Save panel suggests `profile.hosts`; profile names are never paths. The
  service uses exclusive creation (`O_EXCL`, `O_NOFOLLOW`, mode `0600`), writes and
  flushes before reporting success. **Existing destinations cannot be overwritten**,
  including regular files, symbolic/hard links and dangling links. Choosing an
  existing filename reports a visible error even after the panel's overwrite prompt.
  Failed writes can leave a partial new export; the localized error explains this and
  asks for a new filename. Export is not a transactional workspace backup and does
  not promise crash-durable directory publication.

## Actual verification

Environment and cached command forms: [Development](../DEVELOPMENT.md). All file
fixtures used random private temporary directories; none targeted workstation hosts.

- Full **139 package tests** passed: 30 System, 97 Services, 12 Core; parameterized
  cases additional. `/tmp/machosts-text-exchange-tests-final.log`.
- Five new behavior contracts cover mixed CRLF/Unicode/no-final-newline roundtrip,
  enabled aliases/comments and disabled omission, invalid drafts, unsupported UTF-8
  and BOM, byte/line limits, exact 1 MiB file boundary, directory rejection, regular/
  symbolic/hard/dangling-link overwrite rejection, inactive identity/persistence,
  invalid-name atomicity, preserved existing activation and combined live/trash cap.
  Focused run passed: `/tmp/machosts-text-exchange-focused.log`.
- Release build passed: `/tmp/machosts-text-exchange-release-final.log`. Initial
  sandbox build failed on Xcode's existing user manifest-cache restriction; approved
  execution passed.
- Debug build-for-testing passed, including the new exchange XCUITest:
  `/tmp/machosts-text-exchange-debug-final.log`.
- Strict recursive formatting and `git diff --check` passed:
  `/tmp/machosts-text-exchange-format.log`. New view localization coverage passed;
  Release deep/strict signature verification passed:
  `/tmp/machosts-text-exchange-signature.log`.
- `LaunchTests/testTextExchangeOpensWithoutMutatingDraft` covers opening/dismissing
  exchange without altering the selected inactive draft. Native execution was not
  repeated after earlier automation initialization failures. File panels, keyboard/
  VoiceOver, sheet sizing, read-only export, multiwindow snapshot behavior and full
  import/export UI acceptance remain unexecuted. Package tests are not native UI
  acceptance. Existing native editor code is reused unchanged.

No workstation hosts writes/metadata changes, privileged operation, network downloads,
system authorization, publication or successful-apply simulation.

## Follow-up – Versioned MacHosts JSON (October 26, 2026)

- Added the separate version-1 portable source schema, validated/bounded file reads,
  frozen workspace export and exclusive new-file writes. Reused the text exchange
  actor's file boundary with separate 1/32 MiB budgets.
- Added native JSON file panels and nested review: counts, same-name profile counts,
  folder/parent names, complete source selection and bounded parser diagnostics.
  Explicit append remaps every identity/reference, creates inactive local copies,
  preserves existing drafts/trash/app state, and autosaves one draft revision.
  Current combined budgets are checked again at confirmation. Failure preserves the
  review and entire current draft. No replacement, receipt or system write.
- Export omits activation, trash, revisions, remote metadata and system/recovery
  state. Remote source text becomes a local cached copy. Export snapshot is captured
  when the outer sheet opens; existing filenames/links are refused. German/English
  strings and shared busy state cover panels and prevent dismissal during file I/O.
- Format, limits, omissions, invalid-draft behavior and deliberate reimport semantics:
  [JSON exchange](../JSON-EXCHANGE.md). Source text itself is not redacted.

Actual checks (same local environment/cached commands as Development):

- **146 package tests passed**: 30 System, 104 Services, 12 Core, plus parameterized
  cases. Seven new JSON tests cover independent literal version-1 fixture decoding,
  deterministic export, CRLF/Unicode/invalid-draft preservation, omission of runtime
  metadata, folder/ID remapping, same-name reimport, unsupported versions, malformed
  JSON, duplicate/missing/cyclic IDs, byte/line and combined live/trash budgets,
  atomic failure, private persistence without apply, bounded reads and refused
  existing destinations. `/tmp/machosts-json-tests-final.log`.
- Release build passed: `/tmp/machosts-json-release.log`. Initial sandbox attempt
  could not use Xcode's existing manifest cache; approved execution passed.
- Debug build-for-testing passed, including extended exchange-button availability
  assertions: `/tmp/machosts-json-debug.log`. This is compilation, not UI execution.
- Strict recursive formatting and `git diff --check` passed:
  `/tmp/machosts-json-format.log`. Catalog coverage and Release deep/strict signature
  verification passed: `/tmp/machosts-json-signature.log`.

Native JSON panels/review sizing, keyboard/VoiceOver, cancellation, multiwindow
snapshot/review and complete import/export UI acceptance remain **unexecuted**.
Earlier XCUITest automation initialization failures have not been claimed resolved.
No downloads, workstation hosts modifications or privileged operation occurred.
Gates 0/4/5/7 remain open.

## Follow-up – Selective JSON append (October 26, 2026)

- JSON review supports per-profile inclusion while inspecting complete sources,
  select/deselect all, selected profile counts and selected same-name counts.
  Initial selection preserves the previous all-profile/all-folder behavior.
- Users may keep every folder (including empty ones) or only the ancestor closure
  needed by selected profiles. Profile/folder order and source bytes are preserved.
  Folders-only imports are possible; an empty selection disables confirmation.
  The folder disclosure is explicitly labeled as folders in the input file.
- Selection operates on a completely validated frozen document. Unknown profile IDs
  fail explicitly. Excluded objects cannot bypass initial file/graph/source limits.
  Confirmation uses the existing atomic inactive append with fresh IDs and checks
  the selected subset against the latest draft, including trash. A failed import
  preserves the entire draft and review. No replacement or apply occurs.
- Added German/English strings and updated the [format guide](../JSON-EXCHANGE.md).

Actual verification (cached commands from Development, same local toolchain):

- **149 package tests passed** (30 System, 107 Services, 12 Core), including three
  new tests covering ordered source preservation, shared/multilevel ancestors,
  exclusion of unrelated/empty folders, folders-only/empty/root-level selections,
  unknown IDs, selected roundtrip/remapping, current combined budgets, atomic
  rejection, private persistence and absence of apply state.
  `/tmp/machosts-selection-tests.log`.
- Release build and Debug build-for-testing passed:
  `/tmp/machosts-selection-release.log`, `/tmp/machosts-selection-debug.log`.
  Initial sandbox Release attempt could not access Xcode's manifest cache;
  approved execution passed. Debug includes compilation of the existing UI suite;
  no selection UI execution is claimed.
- Strict recursive formatting and `git diff --check` passed:
  `/tmp/machosts-selection-format.log`. All eight added selection strings have
  translated German/English catalog entries. Release deep/strict signature
  verification passed: `/tmp/machosts-selection-signature.log`.

Native panel/selection/sheet sizing, keyboard/VoiceOver, cancellation and multiwindow
acceptance remain **unexecuted**, following earlier automation-initialization
failures. No workstation hosts writes, metadata changes, downloads, privileged
operation or publication occurred. Gates 0/4/5/7 remain open.
