# MacHosts – Recherche und technische Bewertung

Stand: 25. Oktober 2026. Ziel dieser Recherche ist eine neue, vollständig in Swift implementierte macOS-App. Dies ist eine gezielte Quellcodeanalyse der relevanten Abläufe, kein vollständiges Audit und kein Laufzeittest von SwitchHosts.

## 1. Gesicherte Ausgangslage

- Neues, bisher leeres Projektverzeichnis: `machosts`; Produktname: **MacHosts**.
- Vom Nutzer bestätigt: ausschließlich **macOS 27 und Apple Silicon**.
- SwiftUI und native macOS-Bedienung; gesamte eigene Laufzeitlogik in Swift.
- Vertrieb außerhalb des App Store, ohne Apple-Developer-Account oder Developer-ID-Zertifikat. Gatekeeper-Erststart ist akzeptiert.
- Lokal geprüft: Xcode 27.1 (27A9275), Apple Swift 6.4, SDK 27.0, Host macOS 27.0.1, arm64. Dies beschreibt die vorhandene Umgebung, nicht eine Zusicherung über die weltweit neueste Patchversion.
- Der Nutzer hat anschließend die Empfehlungen bestätigt: Admin-Freigabe je Übernahme, lokale Basis plus Remote-Profile und SwitchHosts-Import, Aktivierung bis zum manuellen Ausschalten, Hauptfenster mit Menüleisten-Zugriff, Deutsch/Englisch und MIT-Lizenz. Siehe [Projektskizze](PROJEKTSKIZZE.md).

## 2. SwitchHosts: heutiger Stand statt historischer Annahmen

Der untersuchte `master`-Stand ist Commit `a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd`; `package.json` nennt Version 5.0.3. Der aktuelle Zweig verwendet **Tauri 2, Rust, React, TypeScript, Jotai, Mantine und CodeMirror**. SwitchHosts pauschal als heutige Electron-App zu beschreiben wäre falsch. Einzelne Quellkommentare dokumentieren noch die Portierung aus Electron; die ausführbare Implementierung ist ausschlaggebend.

Quellen: [Repository](https://github.com/oldj/SwitchHosts), [fixierter Paketstand](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/package.json), [Releases](https://github.com/oldj/SwitchHosts/releases).

### Funktionsinventar und Bewertung für MacHosts

| Funktion | SwitchHosts | Empfehlung für MacHosts |
| --- | --- | --- |
| Lokale Hosts-Profile | vorhanden | Kernfunktion |
| Mehrere Profile gleichzeitig | vorhanden | Kernfunktion; gleiche Domain mit verschiedenen IPv4-Adressen als Konflikt behandeln |
| Ordner und Gruppen | vorhanden | Ordner zur Organisation; gegenseitig ausschließende Umgebungen separat modellieren |
| Systemdatei anzeigen | vorhanden | schreibgeschützte Gesamtansicht mit Herkunft |
| Schnellumschaltung | Hauptfenster und Tray | Hauptfenster und `MenuBarExtra` mit identischem Anwendungsdienst |
| Editor | Syntaxfarben, Suche/Ersetzen | nativer Editor, Undo, Tastaturbefehle, Zeilendiagnostik |
| Remote-Profile | URL und weitere Quellen, Refresh | falls gewünscht: HTTPS, lokaler letzter gültiger Stand, Vorschau vor Anwendung |
| Import/Export | JSON, Vorschau, URL-Import | eigenes versioniertes Format; SwitchHosts-Import mit expliziter Versionsunterstützung |
| Papierkorb | Wiederherstellen und endgültiges Löschen | einfaches lokales Wiederherstellen |
| Verlauf/Recovery | Systemhosts-Historie und Fehlerkompensation | exakte Backups, Journal und nachvollziehbarer Istzustand |
| Schreibmodus | Ersetzen oder verwalteter Abschnitt | ausschließlich eigener klar abgegrenzter Abschnitt als Standard |
| Hintergrundkomfort | Autostart, Helper, geplante Aktualisierung | getrennte Entscheidungen; keine implizite dauerhafte Root-Komponente |
| Erweiterungen | HTTP-API, Post-Apply-Kommandos, Proxy | zunächst zurückstellen; zusätzliche Angriffsfläche und Wartung |
| Einzelne Einträge an/aus | Editor bzw. Kommentare als Arbeitsweise | ausdrückliche Produktanforderung: pro Eintrag zusätzlich zum Profil |

### Tatsächlich gelesene Codepfade

Alle folgenden Links sind auf denselben Commit fixiert.

1. [`hosts_apply/aggregate.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/hosts_apply/aggregate.rs): sammelt aktivierte Einträge rekursiv; optionales Deduping führt IPv4 und IPv6 getrennt. Gruppenaktivierung wird vorgelagert im Renderer behandelt. **Ableitung:** MacHosts soll Aktivierungssemantik, Konflikte und Komposition einmal in einer Swift-Domänenschicht definieren, damit verschiedene Bedienwege nicht auseinanderlaufen.
2. [`hosts_apply/write.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/hosts_apply/write.rs): serialisiert eigene Schreibvorgänge, vermeidet identische Writes, hält Originalbytes für Kompensation vor und unterstützt einen verwalteten Abschnitt. Die Abschnittskomposition normalisiert jedoch Trennbereiche. **Ableitung:** eigenes Fremdmaterial außerhalb des MacHosts-Blocks möglichst bytegenau erhalten; mehrdeutige Marker stoppen den Write. Keine Übernahme fremder Marker.
3. [`hosts_apply/elevation.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/hosts_apply/elevation.rs): bevorzugt einen installierten macOS-Helper; verwendet andernfalls derzeit auch `AuthorizationExecuteWithPrivileges` und eine prozessweit gecachte Autorisierung. **Ableitung:** keine blinde Portierung dieses veralteten API-Pfads.
4. [`hosts_apply/helper_admin.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/hosts_apply/helper_admin.rs) und [`helper_proto/daemon.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/helper_proto/daemon.rs): `SMAppService`-Registrierung, Versionsprobe und XPC; Code-Signing-Anforderung prüft die App-Identität. Das Protokoll erlaubt keinen frei wählbaren Schreibpfad. Ad-hoc-Builds werden im untersuchten Registrierungsweg ausdrücklich ausgeschlossen. **Ableitung:** fester Zielpfad ist sinnvoll; dessen Herausgeber-Vertrauensmodell passt nicht unmittelbar zum gewünschten accountlosen Vertrieb.
5. [`storage/transaction.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/storage/transaction.rs): typisierte Ziele, Undo-Journal vor Änderungen, Wiederaufnahme nach Prozessunterbrechung und Behalten eines unvollständig wiederhergestellten Journals. Eigene Kommentare grenzen die Garantie gegenüber mehreren unabhängigen Schreibern ein. **Ableitung:** ebenfalls explizite Transaktionen; Systemdatei und App-Daten sind keine gemeinsame atomare Transaktion.
6. [`refresh.rs`](https://github.com/oldj/SwitchHosts/blob/a43172f5579a01c4a3e785c6c6d4ef7c07aab1bd/src-tauri/src/refresh.rs): Downloads außerhalb des Store-Locks, Serialisierung je Quelle und Prüfung zwischenzeitlich geänderter Quellen. **Ableitung:** Swift-Actors helfen, beseitigen aber Reentranz an `await` nicht automatisch; Revisionsprüfung bleibt erforderlich.

Diese Analyse belegt Wartungs- und Konsistenzanforderungen, keine umfassend validierten Sicherheitslücken. Es wurde kein fremder Anwendungscode übernommen oder ausgeführt.

## 3. Vergleichbare Programme

| Produkt | Nachgewiesene Stärken | Folgerung |
| --- | --- | --- |
| [Gas Mask](https://github.com/2ndalpha/gasmask) | macOS-App mit Menüleiste; lokale, entfernte und kombinierte Hosts-Dateien; Beobachtung der Systemdatei | schlanke Bedienung und Kombination wiederverwendbarer Profile sind sinnvoll; SwiftUI ist kein Ersatz für die nötige Fehlerbehandlung |
| [Hosts.prefpane / Hosts App](https://github.com/specialunderwear/Hosts.prefpane) | einzelne Einträge schalten, externe Änderungen einlesen, Backups; Systemeinträge geschützt | Eintragsschalter und sichere Koexistenz sind wertvoll; heute eine normale App statt altem Systemeinstellungs-Plugin bauen |

Verglichen wurden die offiziellen Projektbeschreibungen, nicht die komplette Implementierung dieser beiden Alternativen. Lizenzstatus und Wartung einer etwaigen übernommenen Komponente müssen vor einer Übernahme separat geprüft werden; vorgesehen ist eine eigenständige Implementierung.

## 4. Swift und native macOS-Integration

[Swift 6.4](https://www.swift.org/blog/swift-6.4-released/) ist veröffentlicht und lokal vorhanden. Die aktuelle Toolchain ist die Basis; neue Sprachfeatures werden nur bei konkretem Nutzen eingesetzt. Kein experimenteller Compiler und keine unnötige Ausreizung neuer APIs.

- Swift-6-Sprachmodus mit vollständiger Concurrency-Prüfung. Toolchain-Version und Sprachmodus nicht gleichsetzen; konkrete Buildsettings im Bootstrap verifizieren.
- `@MainActor` für UI-Zustand, `@Observable` für beobachtbare Modelle, `@State`/`@Bindable` für Besitz und Bindungen. Foundation-/Datei-Arbeit außerhalb des UI-Ausführungspfades; `async` allein macht blockierende Arbeit nicht nebenläufig.
- Kleine `Sendable`-Werttypen für Requests und Ergebnisse, Actors für veränderlichen Store- und Apply-Zustand. Keine pauschalen `@unchecked Sendable`- oder `nonisolated(unsafe)`-Ausnahmen.
- SwiftUI-`App`, `NavigationSplitView`, native Toolbars, `Commands`, `Settings`, `MenuBarExtra`, SF Symbols und String Catalogs. Nur gezielte AppKit-Brücke für einen vollwertigen `NSTextView`-Editor, weiterhin in Swift.
- Aktuelles SDK gibt Standardkomponenten die aktuelle Systemdarstellung. Liquid Glass nur im vorgesehenen Navigations-/Bedienbereich; Editor und Status müssen lesbar bleiben. VoiceOver, Tastatur, Hell/Dunkel, Kontrast, reduzierte Transparenz und Bewegung prüfen.
- `Codable`-Dokument mit Schema-Version unter Application Support ist für die kleine lokale Datenmenge ein begründeter Startpunkt. JSON-Snapshot atomar ersetzen und Migration testen. SwiftData bringt hier ohne nachgewiesenen Bedarf zusätzlichen Migrations- und Beobachtungsaufwand.
- Apple `Logger` ohne Domain-/URL-Geheimnisse, CryptoKit für Vergleichshashes, Foundation/URLSession für optionale Downloads, Security/ServiceManagement nur nach gewähltem Berechtigungsmodell.
- Swift Testing für Domäne, Parser, Migration und Transaktionen; XCTest/XCUITest für UI-Abläufe. Security-relevante Systemintegration zusätzlich in einer wegwerfbaren VM.
- [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) für Benennung; [swift-format](https://github.com/swiftlang/swift-format) als bewusst gewählte Projektformatierung. Es gibt keinen einzelnen offiziell vorgeschriebenen Swift-Einrückungsstandard.

Quellen: [SwiftUI-Modellverwaltung](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app), [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview), [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra), [Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass), [Swift Testing](https://developer.apple.com/documentation/testing), [Concurrency](https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/).

## 5. Accountloser Vertrieb und Administratorrechte

### Signaturbegriffe

„Ohne Signatur“ wird im Projektziel als **ohne Developer ID und ohne Notarisierung** verstanden. Native arm64-Programme benötigen auf Apple Silicon eine Codesignatur; eine **Ad-hoc-Signatur** genügt für diese technische Anforderung und benötigt keinen Apple-Account. Sie bestätigt keine Herausgeberidentität und ist nicht Apples gleichnamige iOS-Verteilung mit registrierten Geräten.

Quellen: [Apple Platform Security](https://support.apple.com/en-au/guide/security/secebb113be1/web), [Apple: eingebettete Tools und Ad-hoc-Signatur](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app). Gatekeeper bleibt aktiv; der dokumentierte individuelle Erststartweg ist [Datenschutz & Sicherheit → Dennoch öffnen](https://support.apple.com/en-euro/guide/mac-help/mh40616/mac). Kein Abschalten von SIP oder Gatekeeper als Installationsvoraussetzung.

### Berechtigungsoptionen

| Option | Nutzen | Kosten / Unsicherheit | Bewertung |
| --- | --- | --- | --- |
| Explizite Systemautorisierung je Übernahme, kurzlebiges Swift-Tool | kleiner privilegierter Umfang, kein persistenter Root-Dienst | OS-Autorisierungsbrücke und sichere Übergabe müssen auf macOS 27 nachgewiesen werden; OS kann Freigaben cachen | bevorzugte Untersuchung für accountlosen Start |
| `SMAppService`-Daemon mit XPC | schnelles Umschalten nach Einrichtung | Nutzerfreigabe, Aufruferprüfung, accountloser Vertrauensanker, Updates und Deinstallation | Alternative bei zwingendem Komfortbedarf; kein bereits bewiesener accountloser Produktionsweg |
| Klassischer root-installierter Helper mit fest gepinntem Buildhash | theoretisch ohne Developer ID konstruierbar | sicherer Installer, vertrauenswürdiges Pinning/Rotation, mehrere Nutzer, komplexe Updates | kein leichtgewichtiger Standardvorschlag |
| `AuthorizationExecuteWithPrivileges` | bestehende Apps nutzen es noch | von Apple ausdrücklich veraltet | für MacHosts nicht vorsehen |
| `chmod`/ACL auf `/etc/hosts`, Root-GUI oder breites `sudoers` | scheinbarer Komfort | erweitert Rechte dauerhaft bzw. übermäßig | ausschließen |

Apple empfiehlt für persistente Dienste [Service Management](https://developer.apple.com/documentation/servicemanagement/smappservice). [Die Registrierung](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) eines Daemons erfordert administrative Zustimmung. Das ist von der Frage getrennt, wie ein Helper seine Aufrufer sicher erkennt. Aus Beispielen mit Developer Team folgt keine Garantie für Ad-hoc-Builds.

Eine untersuchbare Brücke ist ein festes `do shell script … with administrator privileges`, das ausschließlich ein mitgeliefertes Swift-Tool mit engem Requestformat startet. Dies ist OS-Integration, keine Fachlogik in AppleScript. Apples [TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html) beschreibt diesen Weg, ist jedoch archiviert: Verhalten, Dialoge, Caching, Abbruch, sichere Pfad-/Requestübergabe und Unterstützung auf macOS 27 sind **offene Machbarkeitsprüfungen**. Ein frei zusammengesetzter Shellbefehl oder privilegiertes `cp` ist kein ausreichender Produktionsentwurf. Falls „komplett Swift“ auch diese feste Betriebssystembrücke ausschließt, muss eine andere Lösung gewählt werden.

## 6. Sicherheits- und Zuverlässigkeitsanforderungen aus dem Zweck

1. Nur `/private/etc/hosts` als festes privilegiertes Ziel; `/etc` ist auf macOS selbst eine übliche Verknüpfung. Die Ziel-Datei darf nicht beliebigen Symlinks/Hardlinks folgen. Tests müssen normale macOS-Pfadstruktur von einem manipulierten Ziel unterscheiden.
2. Nie Freitext als Shellcode interpretieren. Nur feste Operationen, begrenzte Requestgrößen, striktes Schema, keine frei wählbaren Schreib-/Backup-/Befehlspfade. Alle Prüfungen im privilegierten Tool wiederholen.
3. Vor jeder Mutation Originalbytes und relevante Metadaten sichern; Backupfehler verhindern den Write. Sicheres Staging im Zielverzeichnis, Rechte/Owner/ACL/xattrs explizit behandeln, persistieren, atomar ersetzen, verifizieren. Manipulierte oder unerwartete Metadaten nicht still übernehmen.
4. Istdatei kurz vor Commit gegen erwartete Revision prüfen. Eigene Instanzen serialisieren. Hashprüfung plus Rename ist gegenüber nicht kooperierenden Fremdschreibern keine universelle atomare Compare-and-Swap-Garantie; Restrisiko und Stop-Bedingungen dokumentieren.
5. Fremde Inhalte einschließlich Apple-Standardzeilen erhalten; eigene eindeutige Marker. Fehlende Gegenmarker, verschachtelte oder doppelte Blöcke führen zu einem Konflikt, niemals zu „ab hier alles löschen“.
6. „Gewünscht“, „angewendet“, „extern verändert“ und „unbekannt“ getrennt speichern und anzeigen. Erfolg erst nach Readback; Cache-Flush-Erfolg separat ausweisen.
7. Eine erfolgreiche Änderung der Systemdatei kann trotz anschließend fehlgeschlagener App-Speicherung bestehen bleiben. Vorbereitungsjournal und Readback müssen genau diesen Fall beim Neustart rekonstruieren. Keine blinde automatische Rücksicherung über fremde Änderungen.
8. Remote-Inhalte sind Daten: TLS prüfen, Größen-/Zeit-/Redirectlimits, Herkunft sichtbar, keine eingebetteten Befehle. Private Staging-HTTPS-Ziele können legitim sein; keine pauschale Sperre privater IPs. Jede umgeleitete Herkunft erneut prüfen; keine TLS-Ausnahmen als Standard.
9. Keine Telemetrie, Cloudpflicht oder Netzwerkaktivität bei rein lokalen Profilen. Keine vollständigen Hosts-Inhalte, Credentials oder URL-Tokens in Logs.
10. Vor Auslieferung Angriffsszenarien und Recovery in einer frischen macOS-27-VM prüfen. Keine Testmutation an der Hosts-Datei des Entwicklerrechners.

## 7. Grenzen des Produkts

- Hosts überschreibt Domain-zu-IP-Zuordnung. Keine URL-Pfade, Portumleitung, Wildcards, DNS-Serverfunktion oder CNAME-Semantik versprechen.
- Bei `production.example → Staging-IP` bleiben URL, HTTP-Host und TLS-Servername auf `production.example`. Der Stagingserver muss diese Domain bedienen und ein passendes vertrauenswürdiges Zertifikat liefern. MacHosts soll keine TLS-Prüfung deaktivieren.
- Mehrere Adressen derselben Familie für dieselbe Domain können inkonsistent wirken; Konflikte explizit auflösen, keine allgemeine „erste Zeile gewinnt“-Garantie. IPv4 und IPv6 gemeinsam prüfen, damit ein verbliebener AAAA-Pfad nicht zum falschen Server führt.
- Anwendungen können Auflösung und Verbindungen cachen oder eigene Resolver/Proxys verwenden. Ein OS-Cache-Flush ist keine Zusicherung, dass jeder Browser sofort umschaltet. Diagnose muss Systemauflösung von expliziten DNS-Abfragen unterscheiden; `dig` ist kein Hosts-Wirksamkeitstest.
- Eine geänderte Hosts-Datei überlebt App-Ende und Neustart. Garantiertes Zurücksetzen bei Crash, ausgeschalteter App oder Ablaufzeit erfordert einen gesonderten Lebenszyklus- und Berechtigungsentwurf.

## 8. Ergebnis des Entscheidungsdialogs

Der Nutzer folgt den Empfehlungen. Festgelegt sind: macOS 27, arm64, Swift/native, accountloser Vertrieb mit Ad-hoc-Signatur, bewusste Übernahme mit Systemautorisierung, lokale Basis plus Remote-Profile und SwitchHosts-Import, manuelles Ausschalten, Hauptfenster und Menüleiste, Deutsch/Englisch, MIT-Lizenz.

Die [Projektskizze](PROJEKTSKIZZE.md) und der [Umsetzungsplan](UMSETZUNGSPLAN.md) konkretisieren diese Antworten. Der accountlose privilegierte Schreibweg bleibt ein zwingendes technisches Gate. Die Zustimmung zur Empfehlung ersetzt dessen Nachweis nicht.
