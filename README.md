# MacHosts

A small native macOS app for managing and selectively activating hosts entries for local development. Independently implemented in Swift with SwiftUI for macOS 27 and Apple Silicon.

**Project status: phases 1–3 verified locally; phases 4 and 5 partially implemented. Gates 0, 4, and 5 remain open.** The native Xcode project and Swift package provide parsing/composition, immutable plans, atomic workspace storage, autosave, and local recovery. Apply coordination and the internal transaction engine are verified on private fixtures, including actual process restarts and durable orphan-intent retirement. The production privileged writer remains unavailable.

The local interface includes profiles, trash, folders, cross-profile search, a native editor with syntax colors/line numbers, read-only system contents, and a frozen read-only change preview with mapping differences and conflict provenance. The app remains localized in German and English. Latest verification: 139 package tests, formatting, and Release/Debug test builds passed. The previous missing CoreSimulator framework build blocker no longer reproduces. Full native UI/wake acceptance remains open. See [phase 5](docs/verification/phase-5.md) for results and limits. Independent development continues under [ADR 0002](docs/decisions/0002-deferred-gate-0.md); secure authorization/VM verification remain deferred.

The earlier [phase-0 prototype](Experiments/AuthorizationProbe/README.md) remains separate. Its existing app/ZIP artifacts come from an earlier build. Build commands and toolchain details: [Development](docs/DEVELOPMENT.md). Actual results: [Phase 1](docs/verification/phase-1.md), [Phase 2](docs/verification/phase-2.md), [Phase 3](docs/verification/phase-3.md), [Phase 4](docs/verification/phase-4.md). Formal clean-checkout/CI verification remains open.

Repository documentation and developer-facing text are in English. The MacHosts app retains its German and English localization.

## Documentation

- [Product outline and decisions](docs/PRODUCT-OUTLINE.md)
- [Architecture and safety contracts](docs/ARCHITECTURE.md)
- [Implementation phases and acceptance criteria](docs/IMPLEMENTATION-PLAN.md)
- [Coding instructions and Codex prompts](docs/CODEX-INSTRUCTIONS.md)
- [Research, sources, and SwitchHosts code analysis](docs/RESEARCH.md)
- [Local development and verification commands](docs/DEVELOPMENT.md)
- [Verification reports and decision records](docs/README.md)

The planned version 1 scope covers local and remote profiles, individual entry switches, folders, an editor, menu bar access, conflict checking, previews, backups, recovery, and import/export with explicitly documented SwitchHosts compatibility. Changes remain active until explicitly disabled.

Distribution is planned as an ad-hoc-signed download without Developer ID, notarization, an Apple account, or the App Store. First-launch approval takes place locally in macOS. Source code is available under the [MIT License](LICENSE).


Local `.hosts` exchange is implemented: review UTF-8 text before importing a new
inactive profile, or export original source/enabled entries to a new file. The full
139-test package run and Release/Debug test builds passed. Native file-panel acceptance, remote
profiles, JSON and SwitchHosts exchange remain open. See [phase 7](docs/verification/phase-7.md).
