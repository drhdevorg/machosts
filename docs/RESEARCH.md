# MacHosts – Research and technical assessment

As of October 25, 2026. This investigation supports a new macOS app implemented entirely in Swift. It is a targeted source review of relevant workflows, not a comprehensive audit or runtime test of SwitchHosts. Statements about external products below describe the recorded investigation, not a fresh check during documentation translation.

## 1. Confirmed starting point

- Initially empty project directory: `machosts`; product name: **MacHosts**.
- User-confirmed platform: **macOS 27 and Apple Silicon only**.
- SwiftUI and native macOS interaction; all our runtime logic in Swift.
- Distribution outside the App Store without an Apple Developer account or Developer ID certificate. Individual Gatekeeper first-launch approval is accepted.
- Locally checked: Xcode 27.1 (27A9275), Apple Swift 6.4, SDK 27.0, host macOS 27.0.1, arm64. This records the available environment, not the globally latest patch release.
- The user subsequently confirmed authorization for each explicit apply, local foundation plus remote profiles and SwitchHosts import, activation until manually disabled, main window with menu-bar access, German/English UI, and MIT licensing. See [Product outline](PRODUCT-OUTLINE.md).

## 2. SwitchHosts – Recorded source state rather than historical assumptions

The reviewed `master` commit is `a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd`; `package.json` reports version 5.0.3. That branch uses **Tauri 2, Rust, React, TypeScript, Jotai, Mantine, and CodeMirror**. Calling this implementation an Electron app would be inaccurate. Some comments still describe the Electron port; executable implementation is the authority.

Sources: [Repository](https://github.com/oldj/SwitchHosts), [pinned package](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/package.json), [releases](https://github.com/oldj/SwitchHosts/releases).

### Feature inventory and assessment for MacHosts

| Feature | SwitchHosts | Recommendation for MacHosts |
| --- | --- | --- |
| Local hosts profiles | Available | Core feature |
| Multiple simultaneous profiles | Available | Core feature; different IPv4 addresses for one domain are a conflict |
| Folders and groups | Available | Organizational folders; model mutually exclusive environments separately if introduced |
| System-file display | Available | Read-only full view with provenance |
| Quick switching | Main window and tray | Main window and `MenuBarExtra` using the same application service |
| Editor | Syntax colors, find/replace | Native editor, undo, keyboard commands, line diagnostics |
| Remote profiles | URL/other sources and refresh | HTTPS, last valid local content, preview before application |
| Import/export | JSON, preview, URL import | Own versioned format; explicit supported SwitchHosts versions |
| Trash | Restore and permanent deletion | Simple local restore |
| History/recovery | System-hosts history and error compensation | Exact backups, journals, explainable actual state |
| Write mode | Replace or managed section | Only our clearly delimited section by default |
| Background convenience | Login start, helper, scheduled refresh | Separate decisions; no implicit persistent root component |
| Extensions | HTTP API, post-apply commands, proxy | Defer initially; additional attack surface and maintenance |
| Per-entry switches | Editor/comments as workflow | Explicit requirement in addition to whole-profile activation |

### Code paths actually read

All links below are pinned to the same commit.

1. [`hosts_apply/aggregate.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/hosts_apply/aggregate.rs): recursively collects enabled entries; optional deduplication treats IPv4/IPv6 separately. Group activation is handled earlier in the renderer. **Inference:** define activation, conflicts, and composition once in a Swift domain layer so interaction paths cannot diverge.
2. [`hosts_apply/write.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/hosts_apply/write.rs): serializes its writes, avoids identical writes, retains original bytes for compensation, and supports a managed section. Section composition normalizes separator areas. **Inference:** preserve foreign bytes outside the MacHosts block; ambiguous markers stop writes. Do not adopt foreign markers.
3. [`hosts_apply/elevation.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/hosts_apply/elevation.rs): prefers an installed macOS helper; otherwise also uses `AuthorizationExecuteWithPrivileges` and process-cached authorization. **Inference:** do not blindly port this deprecated API path.
4. [`hosts_apply/helper_admin.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/hosts_apply/helper_admin.rs) and [`helper_proto/daemon.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/helper_proto/daemon.rs): `SMAppService` registration, version probing, and XPC; code-signing requirements check app identity. The protocol allows no arbitrary write path. The reviewed registration path explicitly excludes ad-hoc builds. **Inference:** a fixed destination is useful; its publisher trust model does not directly fit account-free distribution.
5. [`storage/transaction.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/storage/transaction.rs): typed targets, undo journal before changes, resumption after termination, and retention of incompletely restored journals. Comments limit guarantees against independent writers. **Inference:** use explicit transactions; system file and app data do not form one atomic transaction.
6. [`refresh.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/refresh.rs): downloads outside the store lock, per-source serialization, and checks for sources changed in the meantime. **Inference:** Swift actors help but do not automatically remove reentrancy across `await`; revision checks remain necessary.

This analysis supports maintenance/consistency requirements, not comprehensively validated vulnerabilities. No third-party application code was copied or executed.

## 3. Comparable applications

| Product | Documented strengths | Implication |
| --- | --- | --- |
| [Gas Mask](https://github.com/2ndalpha/gasmask) | macOS menu-bar app; local, remote, and combined hosts files; system-file observation | Simple interaction and reusable profiles are useful; SwiftUI does not replace error handling |
| [Hosts.prefpane / Hosts App](https://github.com/specialunderwear/Hosts.prefpane) | Per-entry switches, external-change reload, backups, protected system entries | Entry switches and safe coexistence matter; build a normal app rather than an old settings plugin |

Only official project descriptions were compared, not their complete implementations. Check license and maintenance separately before reusing any component; the planned implementation is independent.

## 4. Swift and native macOS integration

[Swift 6.4](https://www.swift.org/blog/swift-6.4-released/) was recorded as released and locally installed. Use the available toolchain as the basis; adopt new language features only for concrete benefit. No experimental compiler or unnecessary new APIs.

- Swift 6 language mode with complete concurrency checking. Toolchain version and language mode are distinct; verify actual build settings during bootstrap.
- `@MainActor` for UI state, `@Observable` for observable models, `@State`/`@Bindable` for ownership/binding. Foundation/file work stays outside the UI execution path; `async` alone does not make blocking work concurrent.
- Small `Sendable` request/result values; actors for mutable store/apply state. No blanket `@unchecked Sendable` or `nonisolated(unsafe)` exceptions.
- SwiftUI `App`, `NavigationSplitView`, native toolbars, `Commands`, `Settings`, `MenuBarExtra`, SF Symbols, and string catalogs. Targeted Swift AppKit bridge for a complete `NSTextView` editor.
- The SDK supplies system appearance. Use Liquid Glass only in intended navigation/control areas; keep editor/status legible. Test VoiceOver, keyboard, light/dark, contrast, reduced transparency, and motion.
- A schema-versioned `Codable` document under Application Support is a reasonable starting point for small local data. Replace JSON snapshots atomically and test migration. SwiftData adds migration/observation work without demonstrated need here.
- Apple `Logger` without domain/URL secrets; CryptoKit for comparison hashes; Foundation/URLSession for optional downloads; Security/ServiceManagement only according to the chosen authorization model.
- Swift Testing for domain/parser/migration/transactions; XCTest/XCUITest for UI. Security-sensitive integration also needs a disposable VM.
- [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) for naming and [swift-format](https://github.com/swiftlang/swift-format) for explicitly chosen formatting. There is no single officially required Swift indentation style.

Sources: [SwiftUI model data](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app), [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview), [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra), [Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass), [Swift Testing](https://developer.apple.com/documentation/testing), [Concurrency](https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/).

## 5. Account-free distribution and administrator privileges

### Signing terminology

For this project, “unsigned” means **without Developer ID and notarization**. Native arm64 programs need a code signature on Apple Silicon; an **ad-hoc signature** meets that technical requirement without an Apple account. It establishes no publisher identity and is distinct from Apple's similarly named iOS device distribution.

Sources: [Apple Platform Security](https://support.apple.com/en-au/guide/security/secebb113be1/web), [Apple: embedded tools/ad-hoc signing](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app). Gatekeeper stays enabled; the individual first-launch procedure is [Privacy & Security → Open Anyway](https://support.apple.com/en-euro/guide/mac-help/mh40616/mac). Installation must not require disabling SIP or Gatekeeper.

### Authorization options

| Option | Benefit | Cost/uncertainty | Assessment |
| --- | --- | --- | --- |
| Explicit system authorization per apply, short-lived Swift tool | Small privileged scope, no persistent root service | OS bridge and safe transport need proof on macOS 27; OS may cache approval | Preferred account-free investigation |
| `SMAppService` daemon with XPC | Fast switching after setup | User approval, caller checks, account-free trust anchor, updates/removal | Alternative for essential convenience; not a proven account-free production path |
| Classically root-installed helper with pinned build hash | Theoretically investigable without Developer ID | Safe installer, trusted pinning/rotation, multiuser/update complexity | No lightweight default recommendation |
| `AuthorizationExecuteWithPrivileges` | Still used by existing apps | Explicitly deprecated by Apple | Exclude from MacHosts |
| `chmod`/ACL on `/etc/hosts`, root GUI, broad `sudoers` | Apparent convenience | Permanently/excessively broadens privileges | Exclude |

Apple recommends [Service Management](https://developer.apple.com/documentation/servicemanagement/smappservice) for persistent services. Daemon [registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) needs administrative approval. Secure caller identification is a separate issue; team-based examples do not guarantee ad-hoc support.

One investigable bridge is fixed `do shell script … with administrator privileges` launching only an embedded Swift tool with a narrow request format. This is OS integration, not AppleScript business logic. Apple's archived [TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html) describes it; behavior, dialogs, caching, cancellation, safe path/request transport, and macOS-27 support are **open feasibility checks**. A dynamically assembled shell command or privileged `cp` is insufficient production design. If “entirely Swift” also excludes this fixed OS bridge, another solution is required.

## 6. Security and reliability requirements

1. Only `/private/etc/hosts` as the fixed privileged destination; `/etc` is normally a link on macOS. Do not follow arbitrary target symlinks/hardlinks. Distinguish normal macOS path structure from tampering.
2. Never interpret text as shell code. Fixed operations, bounded requests, strict schema, no arbitrary write/backup/command paths. Repeat validation in the privileged tool.
3. Before every mutation, back up original bytes/relevant metadata; backup failure stops the write. Stage securely in the target directory; explicitly handle mode/owner/ACL/xattrs, persist, atomically replace, verify. Do not silently inherit unexpected metadata.
4. Check actual file against expected revision immediately before commit. Serialize cooperating instances. Hash check plus rename is no universal atomic compare-and-swap against external writers; document residual windows and stop conditions.
5. Preserve foreign content including Apple default lines; use unique markers. Missing partners, nested/duplicate blocks are conflicts, never a reason to delete the remainder of a file.
6. Store/display desired, applied, externally changed, and unknown separately. Success requires readback; cache-flush success is separate.
7. A system write may survive a subsequent app-save failure. Preparation journal/readback must reconstruct that exact case on restart. No blind automatic restore over foreign changes.
8. Remote content is data: validate TLS, bound size/time/redirects, show origin, no embedded commands. Private staging HTTPS endpoints can be valid; do not blanket-block private IPs. Validate every redirected origin; no TLS exceptions by default.
9. No telemetry, cloud requirement, or networking for purely local profiles. Never log full hosts content, credentials, or URL tokens.
10. Before delivery, test attack/recovery scenarios in a fresh macOS-27 VM. Never mutate the developer workstation hosts file for testing.

## 7. Product limits

- Hosts overrides domain-to-IP mappings. Do not promise URL paths, port redirection, wildcards, DNS-server functionality, or CNAME semantics.
- For `production.example → staging IP`, URL, HTTP Host, and TLS server name remain `production.example`. Staging must serve that domain with an appropriate trusted certificate. MacHosts must not disable TLS checks.
- Several same-family addresses for one domain can behave inconsistently; resolve conflicts explicitly, without a general “first line wins” guarantee. Check IPv4 and IPv6 together so a remaining AAAA path cannot point to the wrong server.
- Apps can cache resolution/connections or use their own resolvers/proxies. An OS cache flush does not guarantee immediate browser switching. Distinguish system resolution from explicit DNS queries; `dig` does not test hosts-file effect.
- Hosts changes survive app exit/restart. Guaranteed reset on crash, while the app is stopped, or at expiration requires a separate lifecycle/authorization design.

## 8. Decision outcome

The user accepted: macOS 27, arm64, Swift/native, account-free ad-hoc distribution, explicit application with system authorization, local foundation plus remote profiles and SwitchHosts import, manual disable, main window/menu bar, German/English UI, MIT.

The [product outline](PRODUCT-OUTLINE.md) and [implementation plan](IMPLEMENTATION-PLAN.md) specify these decisions. The account-free privileged path remains a mandatory technical gate. Agreement with the recommendation does not replace proof.
