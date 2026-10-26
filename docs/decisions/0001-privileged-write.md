# ADR 0001 – Account-free privileged write path

Date: October 25, 2026. **Status: proposed; security and VM evidence outstanding.** This does not approve running our own process as root. Product decisions remain unchanged.

## Context and trust boundary

MacHosts is to be distributed without Developer ID. An ad-hoc signature establishes executable integrity within a signed build, not reliable publisher identity across updates. At first launch the user trusts the downloaded package. An app cannot protect against replacement of its entire contents solely by checking itself; download verification and local system integrity remain prerequisites.

Separately, the app must prevent replacement of its less protected embedded tool between verification and privileged execution. A path, bundle ID, ordinary-user `chmod`, or a hash check before reopening does not establish that guarantee. An OS password dialog does not prove the code trust path either.

## Current decision

Develop the local prototype without root capability. An optional VM test checks a fixed OS authorization call for Apple's `/usr/bin/id -u`. Our file logic runs only without privileges on a private fixture. Neither the app nor the demo tool supports running as root.

Directly launching a Swift tool from a user-writable bundle through `do shell script … with administrator privileges` is **not approved**. Correct shell quoting does not solve tool provenance, TOCTOU, dynamic library paths, or request integrity.

## Candidate for further investigation

A short-lived tool with protected root-owned staging and explicit system authorization. Bootstrap may use only trusted Apple system programs until our binary has been fully copied into protected storage and verified against an expected digest with a trustworthy binding. No execution from the working directory, Downloads, or `/tmp`.

Prove the following before implementation/acceptance:

1. Establish the expected tool digest's origin in the accepted app build; tool changes must not be silently accepted. Describe whole-app compromise as a separate threat boundary.
2. Use a staging directory without attacker-controlled parents, symlinks, or attacker-held writable descriptors. Prevent replacement after copying/checking. No blind recursive copying or inherited untrusted permissions.
3. Load only system dylibs at runtime; no user-writable `@rpath`, library/configuration paths, or inherited loader environment variables in the privileged tool.
4. Accept requests as immutable, narrowly bounded data with digest binding and transaction state. No general privileged reading/writing of a user path. Never interpret data as shell syntax.
5. Keep bootstrap and cleanup smaller and easier to verify than the rejected persistent-helper architecture. The fixed OS bridge must contain no hosts business logic in shell/AppleScript.
6. Test success, cancellation, timeout, and tool-digest updates in a fresh VM. No unattended root program or security downgrade as fallback.

This is a testable hypothesis, not an implemented or proven-safe bootstrap. Reject the fixed OS bridge if it requires too much security logic in shell to fit the agreed design.

## Alternatives if evidence is negative

| Alternative | Impact |
| --- | --- |
| Manually installed root-owned Swift writer, immutable with a narrow interface | Account-free operation can be investigated; more installation/update work, secure caller authorization still necessary; not an automatically accepted fallback |
| Developer ID and `SMAppService`/XPC with verifiable signing identity | More conventional trust path; conflicts with the confirmed account-free goal and no-persistent-helper decision; requires a new user decision |
| Local profile manager with export and manual system application | No custom root process; substantially reduces integrated switching and requires a product decision |

Deprecated `AuthorizationExecuteWithPrivileges`, a root GUI, broad `sudoers` rules, and permanent hosts write permissions remain excluded. Account-free distribution is not declared impossible; evidence for this particular narrow technical design remains outstanding.

## Evidence and sources

- [Local phase-0 report](../verification/phase-0.md), [experiment](../../Experiments/AuthorizationProbe/README.md).
- [Apple TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html): archived description of OS authorization and quoting; no current runtime evidence.
- [Apple DTS on SMAppService](https://developer.apple.com/forums/thread/802443): documented service structure with a signing team; no guarantee for the account-free candidate.
- [Apple: AuthorizationExecuteWithPrivileges](https://developer.apple.com/documentation/security/authorizationexecutewithprivileges): rejected deprecated API path.

Sources were revisited on October 25, 2026 in the original investigation. Only checks actually executed count as passed. Any later accepted ADR must include the concrete bootstrap, its test artifacts, and remaining threat boundaries.
