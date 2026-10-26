# MacHosts documentation

Repository documentation, filenames, comments, and developer-facing text use English. The product UI remains localized in German and English; multilingual parser/editor fixtures are intentional. The development-only authorization prototype uses English labels.

## Specifications and working agreement

Read these in order before implementation:

1. [Product outline](PRODUCT-OUTLINE.md) – confirmed decisions, workflows, V1 scope, quality targets.
2. [Architecture](ARCHITECTURE.md) – module boundaries, file/privilege/data-integrity contracts.
3. [Implementation plan](IMPLEMENTATION-PLAN.md) – phase dependencies, tasks, acceptance gates, current status.
4. [Codex instructions](CODEX-INSTRUCTIONS.md) – implementation, verification, and reporting workflow.

[Research](RESEARCH.md) records the original technical/source investigation; pinned external-source assessments are historical, not continuously refreshed. [Development](DEVELOPMENT.md) provides exact commands, toolchain/signing details, test isolation, current environment blockers, and implementation notes. The repository-root [README](../README.md) is the entry point; [AGENTS.md](../AGENTS.md) contains the coding-run instructions/status summary.

Specifications describe target behavior, not a claim that all V1 features exist. Verification reports are the authority for actual checks. Within a report, later follow-ups supersede earlier missing-feature statements; historical results do not prove a current bundle build.

## Current status

As of October 25, 2026:

| Area | Evidence/status |
| --- | --- |
| Phase 0 | Local prototype prepared; privileged provenance/transport and VM evidence outstanding; gate deferred |
| Phase 1 | Project and local checks implemented; formal clean-checkout/CI evidence outstanding |
| Phases 2–3 | Parser/composition and workspace storage/recovery gates passed locally |
| Phase 4 | Private transactions/coordinator/restart/observation/retirement verified; production writer and gate open |
| Phase 5 | Local profiles/folders/search/styled editor/system contents implemented; full native acceptance and gate open |
| Latest checks | 114 package tests, app type-check, formatting, native editor probe passed |
| Latest bundle build | Blocked before compilation by missing CoreSimulator framework in Xcode |
| Later phases | Menu bar/login, remote/import/export, hardening, and release remain planned |

No production readiness is claimed. Do not modify workstation hosts bytes, permissions, ownership, or metadata. Local writes use private fixtures only; real privileged system integration requires a confirmed disposable VM. No persistent root helper in V1.

## Architecture decisions

- [ADR 0001 – Account-free privileged write path](decisions/0001-privileged-write.md): proposed candidate and unresolved trust evidence.
- [ADR 0002 – Deferred gate 0](decisions/0002-deferred-gate-0.md): accepted authorization for independent development, preserving production gates.
- [ADR 0003 – Orphan retirement](decisions/0003-orphan-retirement.md): fixture-verified durable replay exclusion, not historical non-commit proof or production approval.

## Verification history

- [Phase 0](verification/phase-0.md): prototype, request/schema/file-boundary tests, packaging, missing VM evidence.
- [Phase 1](verification/phase-1.md): native bootstrap, signing, initial UI test, open infrastructure evidence.
- [Phase 2](verification/phase-2.md): parser/composition/foreign-byte contracts.
- [Phase 3](verification/phase-3.md): initial schema-1 storage/autosave/local recovery.
- [Phase 4](verification/phase-4.md): schema-2 migration, coordinator, private files, process matrices, observation, retirement.
- [Phase 5](verification/phase-5.md): local UI/editor/search/system view, actual checks, native/build blockers.
- [Phase 7](verification/phase-7.md): bounded text import/export, checks and remaining remote/exchange work.
- [Documentation migration](verification/documentation.md): English names/content and reference verification.

Logs/screenshots under `/tmp` are historical local artifacts, not committed evidence bundles; they may be removed by the OS. Generated prototype apps/ZIPs are ignored, and older artifacts do not contain later source updates. Reports distinguish executed checks from planned or unexecuted work.

## Experiments

- [Authorization Probe](../Experiments/AuthorizationProbe/README.md): unprivileged phase-0 model, not an approved root writer.
- [Native Editor Probe](../Experiments/NativeEditorProbe/README.md): reproducible in-process native surface checks, not complete XCUITest/VoiceOver acceptance.

The user guide (`USER-GUIDE.md`) and release report (`verification/release-1.0.md`) are deliverables of later phases and do not exist yet. Their absence is intentional; no placeholder guide or release approval is presented as complete.
