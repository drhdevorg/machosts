# Native editor check

An unprivileged in-process check of the actual `NativeProfileEditor` bridge with `NSHostingView`, `NSTextView`, layout manager, and ruler. No UI scripting/Accessibility automation, app workspace, or system file access. All text is in memory; binary, logs, and rendered PNGs go under `/tmp`. The check briefly opens and closes its own window.

First build/test the package with cache paths from [Development](../../docs/DEVELOPMENT.md). Then run from the repository root with Xcode 27.1:

```sh
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macosx27.0 -module-cache-path /tmp/machosts-product-modules -I /tmp/machosts-product-package/debug -L /tmp/machosts-product-package/debug -lHostsServices -lHostsCore MacHosts/NativeProfileEditor.swift Experiments/NativeEditorProbe/EditorProbe.swift -o /tmp/machosts-editor-probe

/tmp/machosts-editor-probe
```

The Swift macro server requires execution outside the coding sandbox. The check needs a native macOS user session, not root privileges. Do not claim native evidence without successful execution.

Checks exact CRLF/Unicode text, temporary rather than stored syntax attributes, selection, undo/redo, external text replacement with cleared undo, line count including a final empty line, scrolling at 10,000 lines, and rejection of stale styling after rapid source changes. Renders native text/ruler surfaces in Aqua/Dark Aqua under `/tmp/machosts-editor-{text,ruler}-{light,dark}.png`. Surfaces render separately because the tested SDK's parent `NSHostingView` bitmap cache omits layer-backed text.

This does not replace XCUITest, VoiceOver, keyboard acceptance, find/replace/clipboard checks, or performance measurement. Fixed waits serve the local probe only, not a production response-time contract.

Diagnostic navigation additionally checks exact UTF-16 line selection after a Unicode/CRLF prefix, editor focus, preservation of redo/source bytes, and refusal of a stale digest-bound jump.

## System contents extension

The same commands exercise production read-only system mode with in-memory Unicode/CRLF text. Checks cover native selection, the system accessibility identifier, and temporary background highlighting restricted to the validated managed block. Light/dark surfaces render to `/tmp/machosts-system-contents-light.png` and `/tmp/machosts-system-contents-dark.png`. No system file is opened. This extends the surface check; it does not establish full system-sheet or find-bar acceptance.

## Workspace Find/Replace commands

The probe additionally sends the production profile find requests, verifies native Find/Replace bar presentation without changing text/undo, dismisses the bar, and verifies unrelated updates do not reopen it. This does not yet verify entered search/replacement text or app menu/keyboard routing; the isolated menu XCUITest covers those integration entry points when automation is available.

## Undo isolation and shared drafts

The probe creates two native editors in one window and verifies distinct undo managers, including preservation of the other editor's undo after an external replacement. A second window editing the same in-memory draft verifies synchronization, invalidation of the receiving editor's stale undo/redo, and preservation of the originating editor's redo. No workspace or system files are accessed. This does not establish SwiftUI sidebar selection or New Window menu acceptance.
