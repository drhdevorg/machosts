# Phase 5 – Lokaler Profilworkflow (Teilabschluss)

Stand: 25. Oktober 2026. **Phase 5 begonnen; Gate 5 nicht bestanden.** Entwicklung gemäß ADR 0002 unabhängig vom zurückgestellten privilegierten Schreibweg. Gate 0 und Gate 4 bleiben offen.

## Implementierter Umfang

- `ProfileWorkspaceModel` als gemeinsames MainActor-/Observation-Modell für lokale Entwürfe: erstellen, umbenennen, Quelltext bearbeiten, gewünschte Aktivierung, als inaktives lokales Profil duplizieren, Reihenfolge ändern, Papierkorb und inaktiv wiederherstellen. Profile werden ausschließlich in den lokalen Papierkorb verschoben.
- Bestehende `WorkspaceAutosave`-/`WorkspaceStore`-Grenzen wiederverwendet. Das UI-Modell entprellt selbst und erhält über explizites Flush den bestätigten Speicherstatus; `WorkspaceAutosave.schedule` kann dafür ohne zweiten Timer planen. Revisionen, Profil-/Workspace-Limits und Namen werden vor Annahme einer Änderung geprüft. Ungültige Hosts-Syntax bleibt als bearbeitbarer lokaler Entwurf speicherbar; die Parserdiagnostik zeigt das Problem.
- Speichern läuft hinter der Actor-Dateigrenze. Neuere Eingaben während eines Save werden anschließend gespeichert; konkurrierende Flush-Aufrufe teilen denselben Vorgang. Fehler behalten den sichtbaren Entwurf, bieten Retry und behaupten keinen gespeicherten oder angewendeten Erfolg. Externe Workspace-Änderungen sperren weitere Mutationen. Schreibschutzänderungen aktualisieren auch ohne neue Generation das Systembeobachtungsmodell.
- Reguläres Beenden wartet auf den letzten Entwurf. Ein Speicherfehler hält die App geöffnet und erklärt den Grund. SIGKILL/Crash kann weiterhin Eingaben innerhalb des noch nicht gespeicherten Debouncefensters verlieren; kein Versprechen verlustfreier nicht persistierter Tastatureingaben.
- SwiftUI-Sidebar und Detailansicht mit `NSTextView`-Brücke: Monospace, native Auswahl, Undo und Findbar, reine Textbearbeitung ohne automatische typografische Ersetzungen. Profilwechsel erzeugt eine eigene Editoridentität und damit einen eigenen Undo-Kontext. Externe Textänderungen durch Zeilenschalter und abgewiesene Änderungen verwerfen veraltete Undo-Offsets. Findbar-/Undo-Funktionen sind angebunden, ihre vollständige manuelle Abnahme steht aus.
- Parserdiagnostik und Eintragsschalter aus derselben Core-Logik; Zeilenschalter prüfen den dargestellten Quelldigest. Remote-Quelltext ist schreibgeschützt; Duplizieren erzeugt ein inaktives lokales Profil mit neuer ID.
- Sichtbare Trennung von gewünschter Aktivierung, lokalem Speicherstatus und „Noch nicht auf das System angewendet“. Vorhandene Receipts und offene Apply-Absichten werden beim Draftsave erhalten. Der Systemstatus bleibt über ein Sheet erreichbar. Neue/angepasste Texte liegen deutsch/englisch im String Catalog; Quelltext und Eintragsdaten sind keine Übersetzungsschlüssel.
- Native Commands für neues Profil und explizites Speichern. Kein produktiver Systemwriter, keine Apply-Simulation und keine Erfolgshäkchen für Systemänderungen.

## Testumgebung und Isolation

Vorhandene lokale Toolchain: Xcode 27.1 / Swift 6.4, Apple Silicon, Ziel macOS 27.0+. Swift-6-Concurrency-Prüfung aktiv. Zu Runbeginn sauberer Git-Stand `1d573ef`; Änderungen nicht committed. Ein Git-Repository ist inzwischen vorhanden; das ersetzt nicht den offenen formalen Clean-Checkout-/CI-Nachweis.

Alle neuen Modelltests verwenden frische private temporäre Workspace-Verzeichnisse. Nur Debug-Builds bieten den expliziten UI-Testschalter `--ui-testing-local-workspace`: zufälliges privates Verzeichnis, sichtbare Testkennzeichnung, keine Systemdateibeobachtung, keine Pfadparameter und kein simuliertes Apply. Die UI-Tests verwenden ausschließlich diesen Modus. Der Release-Build wertet den Schalter nicht aus. Temporäre UI-Workspaces bleiben zur Diagnose unter `machosts-ui-*` erhalten.

Die Hosts-Datei und der Standard-Workspace des Arbeitsrechners wurden durch diese Tests weder gelesen noch verändert. Keine Systemautorisierung, Root-Ausführung, VM-Tests oder Veröffentlichung.

## Tatsächliche Prüfungen

Befehle mit den bestehenden Cachepfaden aus `docs/ENTWICKLUNG.md`:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules swift test --package-path Packages/MacHostsKit --scratch-path /tmp/machosts-product-package --cache-path /tmp/machosts-product-cache --disable-sandbox

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules swift test --package-path Packages/MacHostsKit --scratch-path /tmp/machosts-product-package --cache-path /tmp/machosts-product-cache --disable-sandbox --filter 'editor|profileEditing|remoteProfile|profileEditor'

xcrun swift-format lint --strict --recursive MacHosts MacHostsApply MacHostsUITests Packages/MacHostsKit

git diff --check

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/machosts-product-derived -packageCachePath /tmp/machosts-product-cache build-for-testing

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/machosts-product-derived -packageCachePath /tmp/machosts-product-cache test-without-building

CLANG_MODULE_CACHE_PATH=/tmp/machosts-product-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-product-modules xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/machosts-product-derived -packageCachePath /tmp/machosts-product-cache build
```

Ergebnisse:

- Gesamtlauf bestanden: 30 System-, 55 Service- und 12 Coretests, zusammen 97 Tests (parametrisierte Fälle zusätzlich). Log `/tmp/machosts-profile-tests.log`. Dieser Lauf enthält die ersten sieben Profilmodelltests und die vorhandenen Transaktions-/Prozesssuiten.
- Anschließend gezielt alle zehn Profilmodelltests bestanden, einschließlich drei später ergänzter Tests für Erhalt von Receipt/Absicht, externe Workspace-Mutation und automatisches Speichern nach Eingabeende. Log `/tmp/machosts-profile-focused-tests.log`. Die übrigen unveränderten Suiten wurden nicht wiederholt.
- Die zehn Modelltests prüfen außerdem Neustart-Roundtrip mit CRLF/Unicode-Kommentar, Aktivierung ohne Receipt, Duplikation/Reihenfolge/Papierkorb, inaktive Wiederherstellung, Remote-Schreibschutz, stale Zeilendigest, Namen/Größenlimits, speicherbare ungültige Syntax, Speicherfehler mit explizitem Retry, neuere Eingaben während Save sowie konkurrierende Flush-Aufrufe und schreibgeschützte neuere Schemata.
- Debug-Testbuild und beide XCUITests bestanden. Nativer Haupttest: Erstellen → Umbenennen → Texteingabe → sichtbare Parserdiagnostik → Korrektur → gewünschte Aktivierung → Speichern → Papierkorb → inaktive Wiederherstellung mit erhaltenem Quelltext. Separater Test prüft die sichtbare fehlende Systemintegration. Log `/tmp/machosts-profile-ui-tests-retry.log`; Ergebnisbundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_17-59-18-+0100.xcresult`.
- Formatprüfung bestanden; Log `/tmp/machosts-profile-format.log`. `git diff --check` bestanden.
- Abschließender Release-Build bestanden; Log `/tmp/machosts-profile-build-final.log`. Keine Warnung aus eigenem Swift-Code; Xcode meldet den mangels Frameworkabhängigkeit ausgelassenen AppIntents-Metadatenschritt.

Der erste Paketbuild fand eine Initialisierungsreihenfolge im neuen Observation-Modell; sie wurde vor dem bestandenen Gesamtlauf korrigiert. Der erste Xcode-Aufruf wurde am bekannten Benutzer-Manifestcache durch die Sandbox blockiert; der freigegebene Wiederholungslauf bestand. Beim ersten nativen Testlauf fehlte im separaten Starttest das Fenster in der Accessibility-Hierarchie; der eigentliche Profilablauf bestand bereits. Die Tests aktivieren die App jetzt ausdrücklich und ignorieren gespeicherte Fensterwiederherstellung. Danach bestanden beide Tests. Das belegt den isolierten Teststart, keine allgemeine Abnahme sämtlicher Fenster-/Wiederöffnen-Szenarien.

## Verbleibende Arbeiten

Editor-Zeilennummern und Syntaxfarben, vollständige Systeminhaltsansicht, eingefrorene Apply-Vorschau und Recovery-Bedienung fehlen weiterhin. Manuelle native Abnahme von Undo/Redo, Findbar/Ersetzen, großen Zwischenablagen, Textauswahl, Fokus/Tastatur, VoiceOver, Deutsch/Englisch und mehreren Fenstern steht aus. Reguläres Beenden nach Speicherfehler ist implementiert, aber nicht als nativer Fehlerdialogtest geprüft. Keine Ressourcen-/Performanceabnahme.

Der produktive Autorisierungsweg bleibt durch Gate 0 gesperrt; echte Apply-/Disable-/Recovery-Abläufe und Gate 4 sind unverändert offen. Der lokale UI-Teilabschluss überspringt diese fachlichen Abhängigkeiten nicht und erfüllt weder Gate 5 noch ein Releasegate.


## Folgeabschluss – Ordner und Suche (25. Oktober 2026)

Dieser Abschnitt ergänzt den oben dokumentierten früheren Teilstand. Phase 5 und Gate 5 bleiben offen.

### Implementierung

- Ordner anlegen, umbenennen, neu zuordnen und unter Geschwistern sortieren. Validierung über den bestehenden Workspacevertrag: keine Zyklen, fehlenden Eltern oder mehr als 16 Ebenen; fehlerhafte Änderungen übernehmen keinerlei Teilmutation. Keine Schemaänderung.
- Ordner entfernen erhält alle Profile und Unterordner und verschiebt sie zum Elternordner. Gelöschte Profile bleiben im Papierkorb; nach Entfernung ihres früheren Ordners stellt der bestehende Vertrag sie inaktiv auf oberster Ebene wieder her. Profilquelltext und Aktivierung bleiben bei organisatorischen Aktionen erhalten.
- Native Ordnerverwaltung und Sidebar mit Hierarchiepfaden, Zuordnung über Profilkontextmenü. Ordner ändern nicht die globale Kompositionsreihenfolge. Explizites Profil-Auf/Ab verschiebt relativ zu sichtbaren Geschwistern und aktualisiert dabei die globale Profilreihenfolge. Alle Änderungen benutzen denselben Autosave-/Fehlerweg. Das Ordnersheet lässt sich auch nach eintretendem Schreibschutz schließen.
- Profilübergreifende literale Suche ohne Beachtung der Groß-/Kleinschreibung auf einem separaten Dienstactor. Namen und Quelltext, auch Remote/deaktiviert; kein Papierkorb, Netzwerk oder Dateizugriff. Ein Treffer je passender Textzeile plus Namenstreffer, höchstens 200 Ergebnisse mit sichtbarem Begrenzungshinweis. Entprellung und Cancellation verhindern die Anzeige überholter Antworten.
- Suchsprung mit Quelldigest und UTF-16-Offsets statt UTF-8-Byteoffsets. Das native Textfeld selektiert und scrollt nur passende Fundstellen, trennt Undo-Gruppen vor dem Suchsprung und übernimmt den Fokus auch bei neu angelegter Editoransicht erst nach Fensteranbindung. `Cmd-Shift-F` und sichtbare Suchaktion; Deutsch/Englisch im String Catalog.
- Zwei zusätzliche native Tests für Ordnerzuordnung/-entfernung und Suche/Textauswahl/Undo/Profilwechsel. Der Testlauf stoppt bei fehlender privater Testkennzeichnung sofort; kein Bearbeitungsschritt nach fehlgeschlagener Isolationsprüfung.

### Tatsächliche Verifikation

Mit den dokumentierten Cachepfaden und Befehlen aus `ENTWICKLUNG.md`:

- Gezielter erster Lauf: alle 14 Profil-/Suchmodelltests bestanden; Log `/tmp/machosts-organization-tests.log`.
- Nach Ergänzung der sichtbaren Geschwisterreihenfolge gesamtes Package bestanden: **30 System-, 63 Service- und 12 Coretests, zusammen 105 Tests** (parametrisierte Fälle zusätzlich). Enthält alle **15 Profil-/Suchmodelltests**, davon fünf neue Tests für Ordner-Restart/Datenerhalt, ungültige Hierarchien, sichtbare Profilreihenfolge, literale UTF-16-Fundstellen mit CRLF/Leerzeilen/Unicode und Ergebnisbegrenzung/neue Snapshots. Log `/tmp/machosts-organization-all-tests.log`.
- Release-Build bestanden; Log `/tmp/machosts-organization-release.log`. Keine Compilerwarnung aus eigenem Code. Xcode meldet den mangels Frameworkabhängigkeit ausgelassenen AppIntents-Metadatenschritt. SwiftPM meldet im sandboxierten Paketlauf die nicht beschreibbaren Benutzer-Cacheverzeichnisse; der Lauf mit privaten Cachepfaden bestand.
- Abschließender Debug-Testbuild einschließlich aller vier UI-Tests bestanden; Log `/tmp/machosts-organization-build-final.log`. Der erste neue Testbuild fand einen falschen XCTest-Selektor (`lastMatch`); vor dem erfolgreichen Build korrigiert. Der erste sandboxierte Xcode-Aufruf scheiterte wie zuvor am Manifestcache; freigegebener Aufruf bestand.
- **Aktueller nativer Lauf nicht bestanden:** bei den ersten Tests fehlte das Fenster in der Accessibility-Hierarchie; später meldete XCTest „Not authorized for performing UI testing actions“. Kein Ordner-/Suchablauf erfolgreich durchlaufen. Log `/tmp/machosts-organization-ui.log`, Bundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_18-07-56-+0100.xcresult`. Exportierte Diagnoseanhänge unter `/tmp/machosts-organization-attachments`.
- Ein gezielter Wiederholungsversuch des Suchtests scheiterte bereits beim Initialisieren des Runners: „Authentifizierung abgebrochen. Canceled by user.“ Log `/tmp/machosts-organization-ui-retry.log`, Bundle `/tmp/machosts-product-derived/Logs/Test/Test-MacHosts-2026.10.25_18-09-16-+0100.xcresult`. Keine weiteren UI-Versuche oder Berechtigungsänderungen. Die früher bestandenen zwei UI-Tests bleiben historische Nachweise des früheren Stands; sie bestätigen die aktuelle Erweiterung nicht.
- Abschließende Formatprüfung und `git diff --check` bestanden; Log `/tmp/machosts-organization-format.log`.

Alle Schreibtests liefen ausschließlich an privaten Fixtures. Die lokale Hosts-Datei einschließlich ihrer Metadaten blieb unverändert. Native Abnahme der neuen Abläufe, Ressourcenmessung und die übrigen oben genannten Editor-/System-/Preview-/Recoveryarbeiten bleiben offen. Für die native Abnahme ist zunächst wieder ein funktionierender macOS-XCUITest-/Accessibility-Zugang erforderlich. Keine produktive Autorisierung, VM-Integration oder Gatefreigabe.

## Folgeabschluss – Editorfarben und Zeilennummern (25. Oktober 2026)

### Implementierung

- `ProfileEditorPresentation` leitet die Syntaxklassifikation aus `HostsDocument` ab. UTF-16-Spans für IP-Adressen, Hostnamen, Kommentare, deaktivierte Einträge und ungültige Zeilen; fehlerhafte Zeilen rot und unterstrichen. Keine zweite Validierungslogik. CR, LF, CRLF und Unicode einschließlich Surrogatpaaren behalten ihre ursprünglichen Offsets und Bytes.
- Darstellungserzeugung auf `ProfileEditorStyler`-Actor, 100 ms Entprellung, Cancellation und Abgleich des aktuellen Quelltexts vor jeder Anwendung. Nur temporäre Layoutmanagerattribute; Textstorage, Auswahl, Typingattribute und Undo bleiben vom Styling unberührt. Externe Textmutationen behalten den bestehenden Undo-Resetvertrag. Abbau der nativen Ansicht storniert die noch offene Darstellungstask.
- Natives vertikales `NSRulerView`: logische Zeilennummern, sichtbarer Ausschnitt per Layoutmanager und binärer Suche, variable Breite, Neuzeichnen beim Scrollen. Leerer Text besitzt Zeile 1, ein finales Zeilenende eine zusätzliche editierbare Leerzeile. Die vollständige Zeilenzählung ist vom begrenzten Parsergebnis getrennt: auch BOM-/Zeilenlimitfehler schneiden das Lineal nicht ab. Remote-Schreibschutz bleibt erhalten. Systemfarben, Monospace-Ziffern und deutsch/englisch lokalisierte Accessibility-Beschriftung.
- Sechs neue Pakettests (parametrisierte Zeilenenden zusätzlich) und ein zusätzlicher XCUITest für Lineal/Text/Undo/Redo. Reproduzierbarer In-Process-Check unter `Experiments/NativeEditorProbe`, der die tatsächliche SwiftUI-/AppKit-Brücke ohne Accessibility-Automation ausführt.

### Tatsächliche Verifikation

Mit den bestehenden Befehlen/Cachepfaden aus `docs/ENTWICKLUNG.md`:

- Abschließendes Gesamtpackage **111 Tests bestanden: 30 System-, 69 Service-, 12 Coretests**, parametrisierte Fälle zusätzlich. Enthält alle sechs neuen Darstellungstests: parsergestützte Stile, Unicode-/UTF-16-Ranges, exakte CR-/LF-/CRLF-Zeilenanfänge, Inlinekommentare, neue Snapshots sowie BOM und mehr als 50.000 Zeilen. Log `/tmp/machosts-editor-tests-final.log`. Im ersten Lauf war ein manuell falsch berechneter UTF-16-Erwartungswert im neuen Test die einzige fehlgeschlagene Prüfung; korrigiert, fokussierter Sechsertest und abschließender Gesamtlauf bestanden.
- Release-Build bestanden, Log `/tmp/machosts-editor-release-final.log`. Debug-Testbuild mit allen fünf UI-Tests bestanden, Log `/tmp/machosts-editor-debug-final.log`. Keine eigene Swift-Compilerwarnung; Xcode meldet weiterhin den ausgelassenen AppIntents-Metadatenschritt. Der erste sandboxierte Xcode-Aufruf wurde wie zuvor am Manifestcache blockiert; freigegebener Build bestand.
- **Nativer In-Process-Check bestanden**, mit dem in `Experiments/NativeEditorProbe/README.md` dokumentierten Swift-Compilerbefehl. Logs `/tmp/machosts-editor-probe-build.log`, `/tmp/machosts-editor-probe.log`. Geprüft: unveränderter CRLF-/Unicode-Text, temporäre Farben und Fehlerunterstreichung, Auswahl nach Eingabe, Undo/Redo nach Styling, externe Ersetzung mit geleertem Undo-Kontext, 10.000 Zeilen/Scrollen und überholte Antworten bei schnellen Quelltextwechseln. Kein Workspace und keine Hosts-Datei geöffnet. Der Probecompiler benötigte wegen seines Makroservers Ausführung außerhalb der Sandbox.
- Native Text- und Linealflächen in Hell/Dunkel gerendert und visuell geprüft: `/tmp/machosts-editor-text-light.png`, `/tmp/machosts-editor-text-dark.png`, `/tmp/machosts-editor-ruler-light.png`, `/tmp/machosts-editor-ruler-dark.png`. Farben, Fehlerunterstreichung und Zeilennummern sichtbar; exakte CRLF-/Unicode-Texte separat im nativen Check geprüft. Der erste Bitmapversuch über die übergeordnete NSHostingView ließ den layerbasierten Text aus; direktes Rendern der nativen Flächen zeigt ihn vollständig. Keine vollständige Fenster-/VoiceOver-Abnahme daraus abgeleitet.
- Formatprüfung einschließlich `Experiments/NativeEditorProbe` und `git diff --check` bestanden; Log `/tmp/machosts-editor-format-final.log`.
- **XCUITest-Ausführung nicht wiederholt**: der zuvor dokumentierte fehlende/abgebrochene Testautorisierungszugang ist nicht geklärt. Der neue UI-Test ist nur gebaut. Keine Berechtigungsänderung und keine neue Behauptung einer bestandenen End-to-End-Abnahme.

### Verbleibende Grenzen

Syntaxfarben/Zeilennummern sind jetzt implementiert und lokal modell- sowie in-process-nativ geprüft. Die oben als fehlend bezeichneten Editorfarben/Zeilennummern sind damit erledigt. Systeminhaltsansicht, eingefrorene Preview und produktive Recovery-Bedienung bleiben offen. Vollständige native Mehrfenster-/Tastatur-/VoiceOver-/Findbar-/Zwischenablageabnahme und Ressourcenmessung bleiben offen; der 10.000-Zeilen-Check ist kein Performancenachweis. Kein produktiver Systemwriter, keine Systemautorisierung, kein lokaler Hosts-Write und keine VM-Integration. Gates 0, 4 und 5 bleiben offen.
