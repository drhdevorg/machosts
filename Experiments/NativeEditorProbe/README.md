# Nativer Editorcheck

Unprivilegierter In-Process-Check der tatsächlichen `NativeProfileEditor`-Brücke mit `NSHostingView`, `NSTextView`, Layoutmanager und Lineal. Keine UI-Scripting-/Accessibility-Automation, kein App-Workspace und kein Systemdateizugriff. Alle Texte liegen im Speicher; Binary, Logs und gerenderte PNGs liegen unter `/tmp`. Der Check öffnet kurz ein eigenes Fenster und schließt es wieder.

Zuerst das Package mit den Cachepfaden aus `docs/ENTWICKLUNG.md` bauen/testen. Dann im Repositoryverzeichnis, mit Xcode 27.1:

```sh
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -target arm64-apple-macosx27.0 -module-cache-path /tmp/machosts-product-modules -I /tmp/machosts-product-package/debug -L /tmp/machosts-product-package/debug -lHostsServices -lHostsCore MacHosts/NativeProfileEditor.swift Experiments/NativeEditorProbe/EditorProbe.swift -o /tmp/machosts-editor-probe

/tmp/machosts-editor-probe
```

Der Swift-Makroserver benötigt in der Coding-Umgebung Ausführung außerhalb der Sandbox. Der Check benötigt eine native macOS-Benutzersitzung, keine Root-Rechte. Ohne erfolgreiche Ausführung keinen nativen Nachweis behaupten.

Prüft exakte CRLF-/Unicode-Texte, temporäre statt gespeicherter Syntaxattribute, Auswahl, Undo/Redo, externe Textwechsel mit geleertem Undo-Kontext, Zeilenzahl einschließlich letzter Leerzeile, Scrollen bei 10.000 Zeilen und Verwerfen überholter Stylingantworten. Rendert die nativen Text- und Linealflächen jeweils in Aqua/Dark Aqua unter `/tmp/machosts-editor-{text,ruler}-{light,dark}.png`. Die Flächen werden separat gerendert, da der Bitmap-Cache der übergeordneten NSHostingView auf dem geprüften SDK den layerbasierten Text auslässt.

Dieser Check ersetzt keine XCUITest-/VoiceOver-/Tastaturabnahme, keine Findbar-/Zwischenablageprüfung und keine Performance-Messung. Feste Wartefenster dienen nur dem lokalen Probeablauf, nicht einem Produktionsvertrag über Antwortzeiten.
