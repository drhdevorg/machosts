# Phase 1 – native Projektbasis

Stand: 25. Oktober 2026. **Implementiert und lokal verifiziert; formaler Clean-Checkout-/CI-Nachweis noch offen.** Gate 0 ist gemäß [ADR 0002](../decisions/0002-deferred-gate-0.md) ausdrücklich zurückgestellt und blockiert diese Arbeiten nicht. Die privilegierte Integration bleibt nicht verfügbar.

## Ergebnis

- Handgeschriebenes `MacHosts.xcodeproj` mit App, eingebettetem `MacHostsApply`, XCUITest-Target, gemeinsamem Scheme und gemeinsamem Testplan.
- Lokales Swift-Package mit `HostsCore`, `HostsServices`, `HostsSystem` und Swift-Testing-Vertragstest. Keine externen Abhängigkeiten oder Projektgeneratoren.
- Native SwiftUI-Startansicht mit Sidebar, Systemzustand und englischem/deutschem String Catalog. Noch keine Profilverwaltung oder Systemübernahme.
- App-UI auf MainActor, Core-/Service-/Systemmodule ohne UI-Default-Isolation, Swift-6-Sprachmodus und vollständige Concurrency-Prüfung. macOS 27.0+, ausschließlich arm64.
- Manuelles Ad-hoc-Signing ohne Teamkonfiguration, Hardened Runtime für App und Tool, eingebettetes Tool vor abschließender Bundle-Signatur. MIT-Lizenz, Formatkonfiguration und [Entwicklungsanleitung](../ENTWICKLUNG.md).
- Nicht verfügbarer Writer wirft immer `integrationUnavailable`; es gibt keine Dateizugriffe oder Autorisierung im Bootstrap. Das CLI beendet sich unprivilegiert mit Exit 69, bei Root laut Code mit Exit 64. Tatsächlicher Root-Start wurde nicht ausgeführt.

## Tatsächlich geprüft

Umgebung: Apple Silicon, Xcode 27.1 (27A9275), Swift 6.4, SDK 27.0. Befehle einschließlich Cachepfaden stehen in der Entwicklungsanleitung.

| Prüfung | Ergebnis / Protokoll |
| --- | --- |
| Swift-Package-Build und Test | bestanden; 1 Swift-Testing-Test; `/tmp/machosts-phase1-swift-test.log` |
| Xcode Debug `build-for-testing` | bestanden; App, Tool und UI-Testtarget; `/tmp/machosts-phase1-xcode-build.log` |
| Xcode Debug `test` nach Testkonfigurationskorrektur | bestanden; 1 XCUITest, 0 Fehler; `/tmp/machosts-phase1-ui-test.log` |
| UI-Verhalten | App gestartet, Hinweis `systemApplyUnavailable` gefunden, App beendet |
| Xcode Release `build` | bestanden; `/tmp/machosts-phase1-release-build.log` |
| Debug- und Release-Bundle `codesign --verify --deep --strict` | bestanden; `/tmp/machosts-phase1-debug-signature.log`, `/tmp/machosts-phase1-release-signature.log` |
| App- und eingebettete Tool-Signaturen | arm64, `Signature=adhoc`, `TeamIdentifier=not set`, Flags `adhoc,runtime` in beiden Konfigurationen |
| Eingebettetes Debug-CLI unprivilegiert gestartet | erwarteter Exit 69 und Meldung über nicht verfügbare Integration |
| Release-Tool `otool -L` | ausschließlich Systembibliotheken unter `/usr/lib` und `/System/Library` |
| Rekursive strikte Formatprüfung | bestanden; `/tmp/machosts-phase1-format.log` |
| Projekt-/Ressourcenformate | `plutil -lint` für pbxproj, JSON-Decoding von Catalog/Testplan/Formatkonfiguration, XML-Parsing des Schemes bestanden |

Die Swift-Package-Prüfung bestätigt die Verfügbarkeitssperre, keine Dateitransaktion. Die UI-Prüfung bestätigt den Start und die Zustandsanzeige, keine visuelle Gesamt-Abnahme oder vollständige Lokalisierungs-/Accessibility-Prüfung. Bestehende Phase-0-Tests wurden ohne Änderungen am Experiment nicht wiederholt.

## Behebbare Probleme aus diesem Run

1. Xcodes Package-Manifestcache liegt trotz umgesetztem Modulcache im Benutzerverzeichnis. Die Coding-Sandbox blockierte ihn; der Build wurde danach mit gezielter Ausführungsfreigabe ohne Root durchgeführt. Keine Systemschutzfunktion geändert.
2. MainActor auf dem gesamten XCTestCase kollidierte mit nichtisolierten geerbten Initialisierern. Nur die Testmethode ist nun MainActor-isoliert; das Testtarget setzt keine UI-Default-Isolation.
3. Explizite Runtime-Signatur des XCTest-Runners verhinderte das Laden des Ad-hoc-Testbundles wegen Library Validation. Ausschließlich das UI-Testtarget verwendet daher keine Hardened Runtime und keine zusätzlichen Signingflags. App und Tool behalten die Runtime-Signatur. Danach bestand der UI-Test.
4. Xcode deaktiviert die automatische Hardened-Runtime-Einstellung bei Ad-hoc-Signing. Explizite `--options runtime` für App/Tool und tatsächliche Signaturprüfung belegen die gewünschten Flags. Der Debug-Dylib-Modus der App ist ausgeschaltet, damit der Debug-App-Einstieg ebenfalls direkt in der eigenen Executable liegt.

Xcode meldete beim ersten Debug-Build eine nicht gestrippte bereits signierte eingebettete Binary; die App-Copy-Phase strippt nun ausdrücklich nicht. Im finalen Build verbleiben Toolchain-Hinweise zur ausgelassenen AppIntents-Metadatenextraktion ohne Framework-Abhängigkeit sowie beim Test ein Debugger-Versionshinweis. Keine Compilerwarnungen im eigenen Swift-Code im finalen Lauf. Der Starttest bestand trotzdem.

## Offene Nachweise und Fortsetzung

Im Arbeitsverzeichnis gibt es weiterhin kein Git-Repository und keine konfigurierte CI. Ein echter Clean Checkout auf einem frischen Benutzerkonto ohne Apple-Login wurde nicht ausgeführt; der vorhandene lokale Build benötigt weder Signing-Team noch Developer-Zertifikat. CI-Runner mit tatsächlich verfügbarem Xcode 27.1 sind nicht nachgewiesen. Diese Infrastrukturpunkte gehören zum noch offenen formalen Gate-1-Abschluss.

Kein Releasepaket und keine Veröffentlichung erzeugt. Keine privilegierten Aufrufe, keine Systemhosts-Datei geöffnet oder verändert. Gate 0 bleibt zurückgestellt; echter Writer, Autorisierung, VM-Integration und Produktionsfreigabe bleiben offen. Nächster fachlicher Block ist Phase 2 (Parser und Komposition); vorher den noch offenen reproduzierbaren Projektaufbau prüfen.
