# Phase 6 – Menu bar, login start, diagnostics (partial)

November 10, 2026. Independent work under ADR 0002. **Gate 6 is open.** Implemented;
package tests and builds verified the same day. Native behavior is not yet tested.

## Implemented behavior

- `MenuBarExtra` (menu style, can be hidden in Settings) shares the app model with all
  windows. It shows the observed system status, unapplied/unsaved draft notices,
  applied profiles only when the system status is confirmed against a receipt-bound
  snapshot, a separate "Desired activation (draft)" submenu, Preview changes (opens the
  same preview sheet in a workspace window), Refresh remote profiles, System file
  status, Diagnostics, Settings and Quit. Menu requests are consumed by exactly one
  workspace window.
- "Disable all MacHosts entries" is **not offered**: it needs the production apply path
  (gate 0/4). No placeholder action exists.
- Closing all windows keeps the app in the menu bar (SwiftUI default; no
  terminate-after-last-window). Quit still flushes drafts first and never touches hosts.
- Settings: opt-in "Open at login" via `SMAppService.mainApp.register/unregister`; the
  toggle reflects the OS status (re-read on activation), `requiresApproval` links to
  Login Items, failures are visible. Remote refresh on launch and interval settings.
- Diagnostics window: `DiagnosticReport` (HostsServices) with app/OS version, apply
  availability, login item status, workspace schema/read-only/recovery/pending state,
  applied receipt readback/cache-flush categories, counts and remote failure
  categories. No names, sources, hostnames or URLs. Copy and explicit Save via panel.

## Verification

Full 164-test package run (including the report-redaction contract test), Release build
with deep/strict ad-hoc+runtime signature verification, Debug build-for-testing and strict
formatting passed. The menu bar, Settings and Diagnostics UI were not exercised natively.

**Open:** native menu/window lifecycle acceptance, login item behavior in an account-free
ad-hoc build (move/update/OS disable), sleep/wake, external-change display in the menu,
warm-menu timing budget, VoiceOver. DNS cache status is not reported. Gate 6 remains open.
