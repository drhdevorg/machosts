# Phase 7 – Text exchange (partial completion)

October 26, 2026. Independent local work under ADR 0002. **Gate 7 is open.**
Only the `.hosts` text exchange increment is implemented. Remote profiles, versioned
MacHosts JSON, SwitchHosts imports, replacement imports, and their acceptance matrices
remain open. Gates 0/4/5 remain open; this increment neither applies nor authorizes
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
