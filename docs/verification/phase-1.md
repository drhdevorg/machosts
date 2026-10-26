# Phase 1 – Native project foundation

As of October 25, 2026. **Implemented and locally verified; formal clean-checkout/CI evidence still open.** [ADR 0002](../decisions/0002-deferred-gate-0.md) explicitly defers gate 0, permitting this work. Privileged integration remains unavailable.

This report records the original phase-1 result. The folder later became a Git repository; the latest environment/build limitations are in [Development](../DEVELOPMENT.md) and [phase 5](phase-5.md).

## Result

- Handwritten `MacHosts.xcodeproj` with app, embedded `MacHostsApply`, XCUITest target, shared scheme/test plan.
- Local package with `HostsCore`, `HostsServices`, `HostsSystem`, and Swift Testing contract test. No external dependencies/project generators.
- Native SwiftUI start view with sidebar, system state, English/German string catalog. No profile management/system apply at this original milestone.
- MainActor UI; Core/Services/System without UI default isolation; Swift 6 language mode, complete concurrency checking; macOS 27.0+, arm64 only.
- Manual ad-hoc signing without team configuration; Hardened Runtime for app/tool; sign embedded tool before bundle. MIT license, formatting configuration, [development guide](../DEVELOPMENT.md).
- Unavailable writer always throws `integrationUnavailable`; bootstrap performs no file access/authorization. CLI exits 69 without privileges and, by code, 64 when root. Actual root startup was not tested.

## Actual checks

Environment: Apple Silicon, Xcode 27.1 (27A9275), Swift 6.4, SDK 27.0. Exact commands/cache paths are in the development guide.

| Check | Result/log |
| --- | --- |
| Package build/test | Passed; 1 Swift Testing test; `/tmp/machosts-phase1-swift-test.log` |
| Xcode Debug `build-for-testing` | Passed; app, tool, UI target; `/tmp/machosts-phase1-xcode-build.log` |
| Xcode Debug `test` after configuration fix | Passed; 1 XCUITest, 0 failures; `/tmp/machosts-phase1-ui-test.log` |
| UI behavior | Launched app, found `systemApplyUnavailable`, terminated app |
| Xcode Release `build` | Passed; `/tmp/machosts-phase1-release-build.log` |
| Debug/Release `codesign --verify --deep --strict` | Passed; `/tmp/machosts-phase1-debug-signature.log`, `/tmp/machosts-phase1-release-signature.log` |
| App/embedded tool signatures | arm64, `Signature=adhoc`, `TeamIdentifier=not set`, flags `adhoc,runtime` in both configurations |
| Embedded Debug CLI, unprivileged | Expected exit 69/unavailable-integration message |
| Release tool `otool -L` | Only system libraries under `/usr/lib` and `/System/Library` |
| Recursive strict formatting | Passed; `/tmp/machosts-phase1-format.log` |
| Project/resource formats | `plutil -lint` on pbxproj, JSON decoding of catalog/test plan/format configuration, scheme XML parsing passed |

The package test proves the availability block, not a transaction. UI evidence proves startup/status display, not full visual/localization/accessibility acceptance. Unchanged phase-0 tests were not rerun.

## Issues resolved during this run

1. Xcode's package manifest cache stays in the user directory despite module-cache overrides. The coding sandbox blocked it; targeted unprivileged execution approval allowed the build. No system protections changed.
2. MainActor isolation of the whole XCTestCase conflicted with inherited nonisolated initializers. Only the test method is now MainActor-isolated; the test target has no UI default isolation.
3. Runtime-signing the XCTest runner blocked ad-hoc bundle loading through library validation. Only the UI test target omits Hardened Runtime/extra signing flags. App/tool retain runtime signatures. The UI test then passed.
4. Xcode disables automatic Hardened Runtime for ad-hoc signing. Explicit `--options runtime` and actual signature checks prove intended app/tool flags. App Debug dylib mode is disabled so its entry point resides directly in its executable.

The initial Debug build reported an unstripped already-signed embedded binary; the app copy phase now explicitly skips stripping. Final toolchain notices concern skipped AppIntents extraction without a framework dependency and a test debugger-version notice. No warnings in our Swift code; startup test passed.

## Outstanding evidence and continuation

At this historical milestone there was no Git repository or configured CI. No actual clean checkout under a fresh user without Apple login was executed. Local builds required no team/developer certificate. Xcode-27.1 CI-runner availability remained unproven. Those infrastructure items keep formal gate 1 open; later Git initialization alone does not close it.

No release package/publication, privileged calls, or workstation hosts access/change. Gate 0 remains deferred; real writer, authorization, VM integration, production approval remain open. The next functional block at this milestone was phase 2, with reproducible setup evidence still outstanding.
