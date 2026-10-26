# ADR 0002 – Defer gate 0 and continue independent development

Date: October 25, 2026. **Status: accepted at the user's explicit request.**

## Decision

Gate 0 is deferred, not passed. The user wants project setup and independent product development to continue and the privileged write path to be resolved later. The previous blanket block on all subsequent phases is removed.

Phases 1–3 may be fully implemented. Phases 4–7 may be prepared and developed using unprivileged private fixtures and an explicitly unavailable system writer; their functional dependencies remain. UI, menu bar, import, and remote features must not report a successful system write. Simulation may run only when visibly identified in tests or an explicitly selected demo mode, never as a silent substitute for actual application.

Gate 0 remains required before enabling the production privileged writer and completing real phase-4 integration. Gates 8 and 9, including production/release approval, still require all actual integration evidence. Partial results are documented separately from passed overall gates.

## Consequences

The authorization adapter remains unavailable until proven. The embedded tool performs no system operations and rejects root startup. Parser, workspace, and UI remain independent of the eventual authorization implementation. Any architectural change resulting from negative phase-0 evidence still requires an ADR.

The workstation's local hosts file, including its metadata, remains excluded as a write target. Real privileged tests remain restricted to a confirmed disposable VM. No persistent root helper, relaxed file permissions, or fabricated success state.

## Supersession

This decision replaces the chronological gate-0 block in earlier planning documents. The security/data-integrity contracts in ADR 0001 and the architecture remain binding. VM tests remain postponed until the user requests their execution and a suitable VM is confirmed.
