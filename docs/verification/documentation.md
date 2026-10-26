# Documentation migration – English filenames and content

Date: October 25, 2026. **Documentation migration complete; no product gate changed.**

## Scope

- Renamed the six German-named planning/development/research files to `PRODUCT-OUTLINE.md`, `ARCHITECTURE.md`, `IMPLEMENTATION-PLAN.md`, `CODEX-INSTRUCTIONS.md`, `DEVELOPMENT.md`, and `RESEARCH.md`.
- Updated repository references and translated remaining documentation: implementation plan, research, development guide, all six phase reports, three ADRs, and both experiment READMEs. Previously translated product/architecture/coding contracts remain intact. Historical repeated caveats were consolidated while preserving results, limits, commands, source links, test counts, and artifact references.
- Added the [documentation index](../README.md), aligned entry-point/development/plan status with phase 5, and clarified historical versus current evidence. Older “no Git repository” statements are explicitly historical. Current status includes implemented system contents, 114 passing package tests, native acceptance gaps, and the latest Xcode framework build blocker.
- Translated development-only Authorization Probe labels/status messages into English. No control flow, authorization command, file operation, or protocol changed. Production app German/English localization and intentional multilingual source fixtures were preserved.
- Later-phase user-guide/release-report deliverables remain explicitly planned, not invented as completed features or approvals. Existing uncommitted implementation work was preserved.

## Verification performed

- Checked all 21 Markdown files and 92 local links/heading anchors: every destination resolves.
- Compared 100 original per-file `/tmp` artifact/log references and 30 external source URLs with translated files: none lost. Original snapshots for this review were kept locally under `/tmp/machosts-docs-before-english`.
- Scanned repository document/source text and filenames for remaining German prose/names and old filename references. Remaining German source strings are intentional parser/editor test fixtures; the product's German text remains in its localization catalog.
- Decoded `MacHosts/Localizable.xcstrings`: source language `en`; all 90 entries have explicit English and German localizations. No catalog content changed in this migration.
- `xcrun swift-format lint --strict Experiments/AuthorizationProbe/Sources/ProbeApp/ProbeApp.swift` passed after formatting the translated labels.
- `git diff --check` passed.

No app build, package tests, native UI, authorization, system-file access, or VM tests were needed/run for this documentation and text-only change. Earlier implementation checks remain recorded in their phase reports; this migration does not resolve the current Xcode/Accessibility blockers, open clean-checkout/CI evidence, or gates 0/4/5.
