# MacHosts – Architecture and contracts

Status: binding target contracts; the concrete authorization implementation must be demonstrated in phase 0. Changes require a reasoned Architecture Decision Record (ADR), not silent relaxation to obtain a green build.

Gate 0 may be deferred under [ADR 0002](decisions/0002-deferred-gate-0.md). Independent product development is permitted; the production privileged writer and integration/release approval remain blocked pending evidence.

## Small module structure

```text
MacHosts.xcodeproj          App, embedded Swift tool, UI tests; shared schemes
MacHosts/                  SwiftUI app, features, narrow AppKit bridge, resources
Packages/MacHostsKit/
  Sources/HostsCore/        Parser, models, composition, conflicts; no UI/root/network
  Sources/HostsServices/    Store, apply coordination, remote, import; no SwiftUI
  Sources/HostsSystem/      Narrow file transaction and request validation for the tool
  Tests/                   Swift Testing suites and own fixtures
MacHostsApply/             Swift entry point for the short-lived privileged tool
MacHostsUITests/           XCTest/XCUITest; environment without real system writes
docs/decisions/            ADRs with status, alternatives, and evidence
docs/verification/         Phase, VM, release, and recovery evidence
```

A manageable Xcode project and local Swift package suffice. No JavaScript/Rust build layer or project generator. Plists, asset catalogs, string catalogs, and optional build/CI configuration are ordinary resources; own executable product logic stays in Swift. Planned filenames are target paths, not assertions that files already exist.

UI → `HostsServices` → `HostsCore`; app → authorization adapter → embedded `MacHostsApply` → `HostsSystem` → `HostsCore`. `HostsSystem` loads no remote URLs or user preferences. The privileged process must be verifiable independently of UI/network state. Reuse common parser logic; never assume the UI already checked it.

## Models and ownership

- `Workspace`: `schemaVersion`, `revision`, profiles, folders, order, and trash. Stable UUIDs; never derive paths from imported IDs.
- `Profile`: ID, name, optional folder, kind (`local` or `remote`), source text, and desired activation. Folders are organizational only.
- `RemoteSource`: validated HTTPS URL, last successful refresh, revision, cache/download status; no stored passwords. Reject URL userinfo. Never export/log URL secrets; authentication management is outside V1.
- `HostsDocument`: line-preserving parse tree with source ranges, original line endings, blank lines, comments, and diagnostics. Do not normalize the system file using `split`/`join`.
- `ApplyPlan`: immutable snapshot of workspace revision, source digests, expected system revision, block operation, preview, conflicts, and plan ID. Any change invalidates it.
- `ApplyReceipt`: transaction ID, before/after digest, backup ID, readback status, and separate cache-flush result. No passwords, shell fragments, or target paths.

Profile source text is the single source of truth for entries; the table is derived. An entry switch comments/uncomments the affected line with reserved documented prefix `# machosts-disabled: `. Never accidentally activate ordinary comments. This syntax is profile-only; the system file contains enabled records and ordinary comments. Remote content is read-only in V1; use “Duplicate as local profile” to edit individual lines. Do not introduce per-line overrides that can shift semantically after refresh.

A switch toggles the entire record when a line contains several hostnames. Split the line to separate names. Never toggle stale source ranges after edits; check the revision and reparse.

## Activation and conflicts

Compose in stable profile/source order. Deduplicate equal normalized domains with identical canonical IPs in generated output, leaving source text unchanged. A domain may have both IPv4 and IPv6. Different active addresses of the same family block V1 apply until resolved, including conflicts with active foreign entries outside the block. Never automatically edit foreign lines.

Actually parse IP literals rather than classify punctuation. Compare hostnames case-insensitively for ASCII. V1 accepts ASCII hostnames, including local single names and explicit Punycode; Unicode comments are allowed. Diagnose Unicode domains clearly rather than implement custom IDNA conversion. Reject ports, URL syntax, wildcards, NUL/control characters, and reserved markers. Define trailing-dot semantics and DNS label limits in parser fixtures. Never silently redirect loopback/system names.

## State and concurrency

`@MainActor @Observable AppModel` owns visible state. Small values cross `Sendable` boundaries. `WorkspaceStore` and `ApplyCoordinator` serialize mutable operations. Actors alone do not prevent overlap across `await`: use an explicit apply state machine and revision checks to prevent concurrent transactions and stale continuations.

```text
idle → preparing → previewReady → authorizing → committing → verifying → applied
             ↘ invalid/conflict       ↘ cancelled/failed         ↘ unknown/recoveryRequired
```

Cancellation before commit makes no system change. Once commit starts, the tool/journal must make the actual outcome recoverable; task cancellation is not rollback. After timeout the UI must not claim nothing happened. `desired` and `applied` are separate snapshots; `externalChange` and `unknown` are explicit states. Cache-flush failure does not turn a confirmed file write into a failed write.

No blocking file I/O on the Main Actor; use a serial file executor or bounded worker behind the service. Do not use `Task.detached` as a blanket actor-error fix. Watch the parent directory or re-register after atomic replacement because the inode can change; debounce events and identify own writes by digest.

## Managed block and foreign content

V1 uses one fixed block:

```text
# >>> MacHosts managed block v1 >>>
# Profile: Shop staging
203.0.113.42 shop.example
# <<< MacHosts managed block v1 <<<
```

Recognize markers only as complete lines. Profile names/comments cannot inject markers or extra lines. Only one block is allowed; missing, duplicate, nested, or reversed markers stop writes. With no block, append one with the required separator and show this in the plan. When disabling the last profile, remove the block and only separator bytes demonstrably added by MacHosts. Preserve all other prefix/suffix bytes. Do not automatically convert foreign encodings; unsupported system files are read-only with clear diagnostics.

SwitchHosts markers are foreign. Import profiles disabled by default, without removing/adopting an existing SwitchHosts block. Migration help explains that active profiles must first be disabled in SwitchHosts to avoid duplicate/conflicting management.

## Privileged boundary – mandatory phase-0 evidence

V1 starts a short-lived Swift tool for each explicit apply through verified OS authorization. A fixed AppleScript OS bridge is a feasibility candidate with archived documentation; neither current behavior nor fitness for this contract is assumed.

The adapter permits no arbitrary commands or content-derived shell syntax. Choose argv/file/pipe request transport only after documenting confidentiality, integrity, size, replay, and lifecycle assessment. An app-owned `0600` JSON file alone is not a safe root input: no-follow opening, immutable snapshots, bounded length, and digest binding are separate requirements.

The tool accepts only version, transaction ID, expected digest, narrowly typed block operations, or a validated backup ID. No target path, program name, or configurable backup path. It computes final content from a fresh file read. Preview metadata cannot replace state checks in the UI/tool.

Fixed target: `/private/etc/hosts`. Check trusted parent, regular file, no unexpected symlinks/hardlinks, owner/mode, and bounded size. Fixed root-owned backup area under `/private/var/db/MacHosts`, tool-managed only. Strictly parse backup IDs; do not use request path segments. Open files/directories without untrusted path resolution. Backup read/export is a narrow operation, never general privileged reading.

Ad-hoc signatures establish no publisher identity. Phase 0 must assess replacement of the executable, loaded libraries, and their paths between selection and privileged launch. A hash-checked file that can subsequently be replaced is insufficient. Never execute Swift sources as root from the workspace, tools from Downloads/`/tmp`, or arbitrary user-writable binaries. The GUI always stays unprivileged.

If safe provenance/transport cannot be demonstrated in the account-free model, record phase 0 as not passed, provide concrete alternatives and costs, and resolve the architecture with the user. Do not fall back to deprecated APIs, broad `sudoers`, permanent hosts write permissions, or an unverified daemon.

## File transaction and recovery

1. Serialize own instances across processes using a trusted lock. Noncooperating external writers remain a documented risk.
2. Safely open the original; validate bytes, metadata, digest, and expected revision.
3. Durably back up original bytes/metadata in protected storage. Backup failure stops writes; safety backup is independent of optional history visibility.
4. Durably store a bounded journal with before/after digests, backup ID, and phase. User journals hold app-snapshot associations, not privileged request paths interpreted as commands.
5. Exclusively create a new file in the trusted target directory; write content, preserve permitted owner/mode and relevant ACL/xattrs, then flush. Reject unexpected flags/metadata rather than ignore them.
6. Recheck revision/identity before replacement, atomically rename, and handle directory durability. Do not claim atomic compare-and-swap against external programs between check and rename.
7. Verify readback/digest and durably store a receipt before saving the app snapshot as applied. Close root journals only after a secured outcome. Retention cannot remove open transactions.
8. Investigate OS DNS cache flush as a separate fixed operation; report success separately. No arbitrary shell hooks or automatic rollback of successful writes on flush failure.

App data and the system file do not form one atomic transaction. After a crash, reconcile actual digest, tool receipt, and open journal. An after-digest match can reconstruct success; a before-digest match does not prove a write. Neither match means unknown/external change requiring manual recovery, never automatic full restore.

Journal-less app intents may be explicitly retired internally under [ADR 0003](decisions/0003-orphan-retirement.md): a durable tombstone fully bound to the intent must exclude every future commit of that ID under the worker lock. Only independent retirement evidence plus freshly read before-bytes permits resolution without a new receipt. `retired` does not assert historical non-commit; missing journals/matching bytes alone remain insufficient. After/foreign bytes stay blocked. Do not remove tombstones without excluding all old requests. Only private adapters implement this contract; production still requires gate 0 and transport/durability evidence.

Full-backup restore needs a fresh preview, system authorization, and expected current digest. Replacing newer foreign changes requires explicit presentation and choice. Normal disable only removes the managed block. Surface multiuser conflicts; V1 permits no silent concurrent workspaces across accounts.

## Storage, limits, and exchange

`~/Library/Application Support/MacHosts/workspace.json` is a versioned atomically replaced snapshot including profile text. `UserDefaults` holds small UI preferences only. Back up before schema migration; treat unknown newer schemas as read-only. Never overwrite corrupt data with an empty workspace. No cloud/sync service.

Initial limits: 1 MiB per profile/download; 4 MiB or 50,000 lines for the resulting system file; 32 MiB per workspace/JSON import; 500 profiles; at most 16 folder levels. Bound streaming downloads, not just headers. Constants need tests and understandable errors; never truncate content. Limit backups, for example to the last 50 completed transactions, excluding initial backup, open transactions, and explicitly preserved recovery points. Document storage/retention at release.

MacHosts JSON has a schema version and exports neither app authorization nor foreign system state. Import preview shows additions, name/ID conflicts, and omitted metadata. Default: append with new IDs and disabled profiles. Workspace replacement needs explicit choice and a prior local backup. `.hosts` export explicitly selects source text or enabled entries.

SwitchHosts importers are pure adapters for fixture-backed documented versions, not direct access to the live `.SwitchHosts` store. Preserve supported folders/profile types, resolve references, and report unknown features. Resolve groups into local profiles only with unambiguous composition shown in the report; cycles/missing references block affected imports. Import performs no system writes or remote downloads.

## Remote, login, and privacy

Use `URLSession`, normal TLS validation, HTTPS, a 30-second request limit, at most three redirects, and four concurrent sources. Validate every redirect URL; do not forward credentials across hosts. No `file://`, HTTP, or custom schemes. Internal staging IPs are permitted. No TLS bypass or built-in custom CA store.

Check source ID/revision after every `await`; stale results cannot restore changed/deleted sources. Honor ETag/Last-Modified; offline/errors preserve the last valid content. New valid data is a saved draft, never a system write. Login start is opt-in through locally verified `SMAppService.mainApp` and reads actual OS status. This unprivileged mechanism is separate from root helpers.

Logs contain operations, error categories, and random IDs only; no profiles, domain lists, or URL tokens. Diagnostic export is explicit with preview/redaction. App Sandbox is not planned; this does not justify extra entitlements. Verify/document Hardened Runtime and genuinely required entitlements at build time without introducing an account requirement.
