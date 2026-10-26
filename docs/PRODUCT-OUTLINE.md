# MacHosts – Product outline

As of October 25, 2026. Status: product direction confirmed in discussion; technical evidence remains outstanding. This describes the target product, not already implemented functionality.

## Product and purpose

MacHosts manages hosts profiles for Mac developers. For example, `203.0.113.42 shop.example` maps a production domain locally to a staging server. The app previews the resulting change and preserves all foreign entries. Disabling removes only mappings managed by MacHosts.

The hosts file affects the entire Mac, not just the signed-in user. MacHosts makes this scope visible. The staging server must serve the domain with an appropriate TLS certificate; port, URL, and certificate redirection are outside the app.

## Confirmed decisions

| Topic | Decision |
| --- | --- |
| Name | MacHosts |
| Platform | macOS 27.0+, arm64 / Apple Silicon only |
| Implementation | Own runtime logic entirely Swift; SwiftUI, targeted AppKit for the editor |
| Toolchain | Existing Xcode 27.1 / Swift 6.4 as starting point; pin a stable version during bootstrap |
| Distribution | Outside the App Store, without an Apple Developer account, Developer ID, or notarization |
| Technical signature | Ad-hoc; no publisher certificate; first-launch Gatekeeper exception accepted |
| Authorization | Explicit apply with macOS system authorization; no persistent root service in V1 |
| Duration | Until manually disabled; survives app exit and restart |
| Interface | Native main window with sidebar/editor, plus menu bar |
| Languages | German and English in the app; English code, technical identifiers, and repository documentation |
| License | MIT, independent implementation |
| V1 scope | Local foundation plus remote profiles and SwitchHosts import |

A small fixed OS authorization bridge may launch a Swift process; parsing, file transactions, and product rules remain Swift. This integration is a hypothesis requiring evidence. No AppleScript business logic or additional language runtime.

## Workflows

### First launch

1. Copy the app to Applications and perform individual macOS first-launch approval if necessary.
2. Briefly explain that changes are system-wide, remain active after quitting, and require administrative approval.
3. Read the current hosts file only; no write or admin prompt at startup.
4. Create an example profile only through an explicit action; never activate automatically. Show existing foreign hosts management.

### Edit and apply a profile

1. Create/select a profile, write entries, enable individual entries or the whole profile.
2. Autosave locally with a clear “Not yet applied” indication.
3. “Apply” opens a diff showing added/removed mappings, active profiles, and conflicts.
4. After confirmation, request system authorization. The OS decides whether another dialog is needed; do not promise a password prompt for every action.
5. Display the applied state only after successful file verification. Cancellation keeps the draft and previous actual state.

Main-window activation initially changes the desired configuration. Saving and applying are visibly separate so multiple changes can be applied together.

### Menu bar quick action

Show applied profiles, pending changes, and system state. “Enable and apply profile” uses the same preview/authorization path as the main window with a compact preview. Show the full scope of existing draft changes before applying; neither silently include nor discard them. On errors, checkmarks must still represent the confirmed state.

“Disable all MacHosts entries” is always reachable and, after preview/approval, removes only the managed section. It does not restore the entire system file from an old copy.

### External changes and recovery

Changes by Terminal, VPN, or another app display “Externally changed”. New previews use the current state. Never silently overwrite externally modified managed blocks. Conflicting markers or an open journal block further writes pending resolution; reading/export remain available.

### Remote profiles

Add an HTTPS URL, download, inspect origin/changes, then explicitly enable/apply. A download never automatically changes `/etc/hosts`. Keep the last valid content offline; invalid downloads cannot replace valid cache.

Manual refresh is part of V1. Optional startup/interval refresh runs only while the app is open, uses demand-driven timers, and performs at most one overdue refresh per source after sleep. No background service or minute-by-minute polling of every source.

## V1 feature scope

| Area | Required |
| --- | --- |
| Profiles | Create, name, duplicate, sort, enable, delete, and restore locally |
| Organization | Folders with stable ordering; folders do not control activation |
| Entries | IPv4/IPv6, multiple hostnames per line, comments, individual line switches |
| Composition | Multiple active profiles, deterministic output, entry provenance, conflicts |
| Editor | Monospace, native selection/undo, line numbers, syntax colors, profile find/replace, cross-profile search |
| Validation | Invalid IP/hostname, duplicates, conflicting mappings, reserved markers |
| System view | Entire file read-only, highlighted managed section, external-change status |
| Safety | Preview, system authorization, narrow Swift tool, backup, journal, readback |
| Recovery | Disable managed mappings, view/export backups, controlled restore |
| Remote | HTTPS, bounded downloads, cache, manual/optional in-process refresh, no automatic apply |
| Exchange | `.hosts` import/export, versioned MacHosts JSON, SwitchHosts import with preview/report |
| Integration | Menu bar, optional login start, standard menus/keyboard shortcuts |
| Quality | German/English, light/dark, VoiceOver, keyboard, system appearance, error messages |

SwitchHosts parity is selective rather than complete. Define/document supported export versions using real fixtures. Unknown versions must not be reported as successfully imported on a “best effort” basis.

## Explicitly deferred beyond V1

- HTTP API, CLI, global hotkeys, App Intents, and URL-scheme control.
- Post-apply shell commands, proxy management, and unattended remote apply.
- Expiration/automatic disable on exit/crash and persistent privileged helpers.
- Mutually exclusive profile groups and complex reference graphs in the native data model.
- Cloud sync, team accounts, million-entry blocklists, and custom DNS/proxy technology.
- Automatic app updates; V1 uses manual release downloads.
- Intel and older macOS versions.

## Quality targets

Correctness comes first: no foreign hosts data loss, false success state, or generic privileged command. Local profiles work fully offline without telemetry. Start without third-party runtime dependencies; additions need concrete value and documented licenses.

Provisional Release-build budgets on a documented Apple Silicon device: interactive main window within two seconds for 100 profiles/10,000 total lines; warm menu within 150 ms; no perceptible typing/scrolling stalls; no periodic networking while locally idle; average below 1% of one CPU core over 60 seconds. A bundle at most 40 MiB and empty-editor RSS at most 150 MiB are investigation targets, not measured properties. Analyze and justify larger values.

## Production readiness

Declare readiness only after phase gates, privileged flows in a fresh macOS-27 VM, recovery checks, native UI acceptance, and install/update/removal with the actual download artifact pass. Open privilege/data-loss issues block release. A plan alone is no evidence of readiness.

Details: [Architecture](ARCHITECTURE.md), [Implementation plan](IMPLEMENTATION-PLAN.md), [Codex instructions](CODEX-INSTRUCTIONS.md), [Research and sources](RESEARCH.md).
