# MacHosts – Architektur und Verträge

Status: verbindliche Zielverträge; konkrete Autorisierungsimplementierung wird in Phase 0 nachgewiesen. Änderungen daran benötigen ein begründetes Architecture Decision Record (ADR), kein stilles Aufweichen für einen grünen Build.

Gate 0 darf gemäß [ADR 0002](decisions/0002-deferred-gate-0.md) zurückgestellt werden. Unabhängige Produktentwicklung ist erlaubt; produktiver privilegierter Writer und Integrations-/Releasefreigabe bleiben bis zum Nachweis gesperrt.

## Kleine Modulstruktur

```text
MacHosts.xcodeproj          App, eingebettetes Swift-Tool, UI-Tests; shared schemes
MacHosts/                  SwiftUI-App, Features, schmale AppKit-Brücke, Ressourcen
Packages/MacHostsKit/
  Sources/HostsCore/        Parser, Modelle, Komposition, Konflikte; ohne UI/Root/Netzwerk
  Sources/HostsServices/    Store, Apply-Koordination, Remote, Import; ohne SwiftUI
  Sources/HostsSystem/      enge Dateitransaktion und Requestvalidierung für Tool
  Tests/                   Swift-Testing-Suites und eigene Fixtures
MacHostsApply/             Swift-Einstiegspunkt des kurzlebigen privilegierten Tools
MacHostsUITests/           XCTest/XCUITest; Testumgebung ohne echte Systemwrites
docs/decisions/            ADRs mit Status, Alternativen, Nachweisen
docs/verification/         Phasen-, VM-, Release- und Recovery-Nachweise
```

Eine handhabbare Xcode-Projektdatei und ein lokales Swift-Package reichen. Kein vorgeschaltetes JavaScript-/Rust- oder Projektgeneratorsystem. Plists, Asset Catalogs, String Catalogs und optionale Build-/CI-Konfiguration sind normale Projektressourcen; eigene ausführbare Produktlogik bleibt Swift. Dateinamen im Plan sind Zielpfade, nicht schon existierende Dateien.

UI → `HostsServices` → `HostsCore`; App → Autorisierungsadapter → eingebettetes `MacHostsApply` → `HostsSystem` → `HostsCore`. `HostsSystem` lädt keine Remote-URLs und keine Benutzereinstellungen. Der privilegierte Prozess ist unabhängig vom UI- und Netzwerkzustand validierbar. Gemeinsame Parserlogik wird wiederverwendet, niemals als „hat die UI schon geprüft“ vorausgesetzt.

## Modelle und eindeutige Zuständigkeit

- `Workspace`: `schemaVersion`, `revision`, Profile, Ordner, Reihenfolge und Papierkorb. Stabile UUIDs; keine Pfade aus importierten IDs ableiten.
- `Profile`: ID, Name, optionaler Ordner, Art (`local` oder `remote`), Quelltext und gewünschte Aktivierung. Ordner sind nur Organisation.
- `RemoteSource`: geprüfte HTTPS-URL, letzte erfolgreiche Aktualisierung, Revision, Cache-/Downloadstatus; keine gespeicherten Passwörter. URL-Userinfo ablehnen. Geheimnisse in URLs weder exportieren noch loggen; Authentifizierungsverwaltung ist nicht V1.
- `HostsDocument`: zeilentreuer Parsebaum mit Quellbereichen, Originalzeilenenden, Leerzeilen, Kommentaren und Diagnostik. Nicht mit `split`/`join` die ganze Systemdatei normalisieren.
- `ApplyPlan`: unveränderlicher Snapshot aus Workspace-Revision, Quelldigests, erwarteter Systemrevision, Blockoperation, Vorschau, Konflikten und Plan-ID. Jede Änderung macht den alten Plan ungültig.
- `ApplyReceipt`: Transaktions-ID, Vorher-/Nachher-Digest, Backup-ID, Readbackstatus und separat Cache-Flush-Ergebnis. Keine Kennwörter, Shellfragmente oder Zielpfade.

Der Profilquelltext ist die einzige Wahrheit für Einträge. Die Tabellenansicht wird daraus abgeleitet. Ein Eintragsschalter kommentiert/entkommentiert die betroffene Zeile mit einem reservierten, dokumentierten Präfix `# machosts-disabled: `. Ein beliebiger Kommentar wird nie versehentlich aktiviert. Diese Syntax ist nur im Profil erlaubt; die Systemdatei enthält nur aktivierte Datensätze und gewöhnliche Kommentare. Bei Remote-Profilen ist V1 der Inhalt schreibgeschützt: einzelne Zeilen werden durch „Als lokales Profil duplizieren“ bearbeitbar. Per-Zeile-Overrides, die bei einem Remote-Refresh semantisch verrutschen könnten, werden nicht eingeführt.

Bei mehreren Hostnamen in einer Zeile schaltet der Zeilenschalter den ganzen Datensatz. Einzelne Hostnamen können durch Aufteilen der Zeile getrennt werden. Nach Textänderungen keine Toggle-Aktion mit veralteten Quellbereichen ausführen; Revision prüfen und neu parsen.

## Aktivierung und Konflikte

Komposition folgt stabiler Profilreihenfolge und Quellreihenfolge. Gleiche normalisierte Domain und identische kanonische IP werden in der generierten Ausgabe dedupliziert; Quelltexte bleiben unverändert. Derselben Domain dürfen IPv4 und IPv6 zugeordnet sein. Verschiedene aktive Adressen derselben Familie blockieren in V1 die Übernahme, bis der Nutzer den Konflikt auflöst. Das gilt auch gegenüber fremden aktiven Einträgen außerhalb des Blocks; fremde Zeilen werden dabei nie automatisch editiert.

IP-Literale tatsächlich parsen, nicht nur anhand von Punkten/Doppelpunkten klassifizieren. Hostnamen ohne Beachtung der ASCII-Groß-/Kleinschreibung vergleichen. V1 akzeptiert ASCII-Hostnamen einschließlich lokaler Einzelnamen und expliziter Punycode-Form; Unicode im Kommentar ist erlaubt. Unicode-Domains erhalten eine verständliche Fehlermeldung statt einer selbstgebauten IDNA-Konvertierung. Ports, URL-Syntax, Wildcards, NUL/Steuerzeichen und reservierte Marker ablehnen. Finale-Punkt-Semantik und zulässige DNS-Labelgrenzen in Parserfixtures festlegen. Loopback- und Systemnamen nicht still umbiegen.

## Zustand und Nebenläufigkeit

`@MainActor @Observable AppModel` besitzt den sichtbaren Zustand. Kleine Werte passieren `Sendable`-Grenzen. `WorkspaceStore` und `ApplyCoordinator` serialisieren veränderliche Abläufe. Ein Actor allein verhindert keine Überlappung über `await`: eine ausdrückliche Apply-Zustandsmaschine und Revisionsprüfung verhindern parallele Transaktionen und veraltete Fortsetzungen.

```text
idle → preparing → previewReady → authorizing → committing → verifying → applied
             ↘ invalid/conflict       ↘ cancelled/failed         ↘ unknown/recoveryRequired
```

Einbruch von Cancellation vor Commit: keine Systemänderung. Nach Beginn des Commit müssen Tool und Journal den tatsächlichen Ausgang rekonstruierbar machen; Task-Cancellation ist keine Rücknahme. UI darf nach Timeout nicht behaupten, es sei nichts passiert. `desired` und `applied` sind getrennte Snapshots, `externalChange` und `unknown` explizite Zustände. Ein Fehler beim Cache-Flush macht einen bestätigten File-Write nicht zu einem fehlgeschlagenen Write.

Kein blockierendes Datei-I/O auf dem Main Actor; serieller Dateiexecutor bzw. begrenzte Workerarbeit hinter dem Dienst. Kein `Task.detached` als pauschale Reparatur für Actorfehler. Dateibeobachtung muss das Elternverzeichnis überwachen oder nach atomarem Ersetzen neu registrieren, da sich der Inode ändern kann; Ereignisse entprellen und selbst ausgelöste Writes per Digest erkennen.

## Eigener Abschnitt und fremde Inhalte

V1 verwendet einen festen Block:

```text
# >>> MacHosts managed block v1 >>>
# Profile: Shop staging
203.0.113.42 shop.example
# <<< MacHosts managed block v1 <<<
```

Marker werden nur als ganze Zeile erkannt. Profilnamen/Kommentare dürfen weder Marker noch zusätzliche Zeilen injizieren. Ein Block ist zulässig; fehlende, doppelte, verschachtelte oder umgekehrte Marker stoppen den Write. Kein Block vorhanden: neuen mit notwendigem Zeilentrenner anhängen und im Plan ausweisen. Beim letzten Ausschalten den Block entfernen; nur eigene, nachweisbar hinzugefügte Trennbytes entfernen. Präfix und Suffix bleiben sonst byteidentisch. Fremde Kodierung nicht automatisch konvertieren; nicht unterstützte Systemdateien nur lesbar öffnen und mit klarer Diagnose stoppen.

SwitchHosts-Marker sind fremdes Material. Ein Import importiert Profile standardmäßig deaktiviert. Er entfernt oder übernimmt keinen bestehenden SwitchHosts-Block. Migrationshilfe erklärt, dass alte aktive Profile zunächst in SwitchHosts deaktiviert werden müssen. Dies verhindert doppelte oder widersprüchliche Verwaltung.

## Privilegierte Grenze – zwingender Nachweis in Phase 0

V1 startet pro bewusster Übernahme ein kurzlebiges Swift-Tool über eine geprüfte Betriebssystem-Autorisierung. Die Machbarkeitskandidatin ist eine feste AppleScript-OS-Brücke; die Dokumentation dazu ist archiviert. Es wird weder deren aktuelles Verhalten noch ihre Eignung für den hier geforderten Sicherheitsvertrag vorausgesetzt.

Der Adapter erlaubt keine freien Befehle und keine aus Inhalt zusammengesetzte Shellsyntax. Eine Requestübergabe über argv, Datei oder Pipe darf erst nach dokumentierter Bewertung von Vertraulichkeit, Integrität, Größe, Replay und Lebenszyklus gewählt werden. Eine app-eigene JSON-Datei mit `0600` allein beweist keinen sicheren Root-Eingang: Öffnen ohne Symlink-Folgen, unveränderlicher Requestsnapshot, begrenzte Länge und Digestbindung sind gesondert erforderlich.

Das Tool akzeptiert ausschließlich Version, Transaktions-ID, erwarteten Digest und eng typisierte Blockoperationen bzw. eine validierte Backup-ID. Kein Zielpfad, Programmname oder frei wählbarer Backup-Pfad. Es berechnet den endgültigen Dateiinhalt aus der frisch gelesenen Datei selbst. Zustandsprüfung in UI und Tool wird nicht durch eine Vorschau-Angabe ersetzt.

Fester Zielpfad `/private/etc/hosts`. Prüfen: vertrauenswürdiges Elternverzeichnis, reguläre Datei, keine unerwarteten Symlinks/Hardlinks, Eigentümer und Modus, begrenzte Größe. Fester root-eigener Backupbereich unter `/private/var/db/MacHosts`, nur vom Tool verwaltet. Backup-IDs strikt parsen, keine Pfadsegmente aus Requests übernehmen, Verzeichnis und Dateien ohne untrusted Pfadauflösung öffnen. Lesen/Export von Backups wird als enge Operation gestaltet; keine allgemeine privilegierte Lesefunktion.

Ad-hoc-Signaturen stellen keine Herausgeberidentität her. Phase 0 muss deshalb insbesondere das ausführbare Tool, alle geladenen Libraries und ihre Pfade zwischen Auswahl und privilegiertem Start gegen Ersetzung bewerten. Eine hashgeprüfte, aber anschließend wieder austauschbare Datei reicht nicht. Kein Root-Ausführen von Swift-Quellen aus dem Arbeitsverzeichnis, kein Tool aus Downloads/`/tmp`, keine implizite Ausführung einer beliebigen nutzerbeschreibbaren Binary. App-GUI bleibt immer unprivilegiert.

Falls sich sichere Toolherkunft/Übergabe im accountlosen Modell nicht belegen lässt: Phase 0 als nicht bestanden dokumentieren, konkrete Alternativen mit Kosten vorlegen und diese Architekturentscheidung im Dialog klären. Nicht auf veraltete APIs, weite `sudoers`-Regeln, dauerhafte Hosts-Schreibrechte oder einen ungeprüften Daemon ausweichen.

## Dateitransaktion und Recovery

1. Eigene Instanzen prozessübergreifend über einen vertrauenswürdigen Lock serialisieren. Ein nicht kooperierender Fremdschreiber bleibt ein dokumentiertes Restrisiko.
2. Originaldatei sicher öffnen und Originalbytes, Metadaten und Digest prüfen; erwartete Revision muss passen.
3. Originalbytes und Metadaten im geschützten Backupbereich dauerhaft sichern; Backupfehler stoppen den Write. Sicherheitskopie ist unabhängig von optionaler Verlaufssichtbarkeit.
4. Begrenztes Transaktionsjournal mit Vorher-/Nachher-Digest, Backup-ID und Phase dauerhaft speichern. User-Journal enthält nur App-Snapshot-Zuordnung und nicht privilegierte Requestpfade als Befehle.
5. Neue Datei exklusiv im vertrauenswürdigen Zielverzeichnis anlegen; Inhalt schreiben, zulässigen Owner/Modus und relevante ACL/xattrs übernehmen, flushen. Unerwartete Dateiflags/Metadaten ablehnen statt ignorieren.
6. Vor Ersetzen erneut Revision und Dateiidentität prüfen, atomar umbenennen und notwendige Verzeichnis-Persistenz behandeln. Kein Anspruch eines atomaren Compare-and-Swap gegenüber fremden Programmen zwischen Prüfung und Rename.
7. Readback und Digest verifizieren, Receipt dauerhaft ablegen; danach App-Snapshot als angewendet speichern. Root-Journal nur nach gesichertem Ausgang abschließen. Aufbewahrungsgrenzen dürfen offene Transaktionen nicht beseitigen.
8. OS-DNS-Cache-Flush als feste getrennte Operation untersuchen, Erfolg separat melden. Keine beliebigen Shell-Hooks. Einen erfolgreichen Write bei Flushfehler nicht automatisch zurückrollen.

App- und Systemdatei sind keine gemeinsame atomare Transaktion. Nach Crash: tatsächlichen Digest, Toolreceipt und offenes Journal abgleichen. Passt der Iststand zum Nachher-Digest, kann die App den Erfolg rekonstruieren. Passt er zum Vorher-Digest, ist kein Write nachgewiesen. Passt er zu keinem, „unbekannt/extern geändert“ mit manueller Recovery, keine automatische Vollrücksicherung.

Journal-lose App-Absichten dürfen intern gemäß [ADR 0003](decisions/0003-orphan-retirement.md) ausdrücklich stillgelegt werden: ein dauerhaft gespeicherter, vollständig an die Absicht gebundener Sperreintrag muss unter dem Workerlock alle zukünftigen Commits dieser ID ausschließen. Erst unabhängiger Nachweis dieser Stilllegung plus frisch gelesene Vorher-Bytes erlaubt das Auflösen ohne neuen Receipt. `retired` behauptet keinen historischen Nicht-Commit; fehlende Journale oder passende Bytes allein bleiben unzureichend. Nachher-/Fremdbytes bleiben gesperrt. Stilllegungen dürfen ohne Ausschluss sämtlicher alter Requests nicht entfernt werden. Nur private Adapter implementieren den Vertrag; produktive Nutzung benötigt weiterhin Gate 0 und einen eigenen Transport-/Persistenznachweis.

Wiederherstellung eines Vollbackups benötigt frische Vorschau, Systemautorisierung und den erwarteten aktuellen Digest. Sie darf fremde neuere Änderungen nur nach expliziter Darstellung und bewusster Auswahl ersetzen. Für normales Ausschalten wird ausschließlich der eigene Block entfernt. Ein Multiuser-Konflikt wird als solcher sichtbar; V1 erlaubt keine stillen konkurrierenden Workspaces verschiedener Accounts.

## Speicherung, Limits und Austausch

`~/Library/Application Support/MacHosts/workspace.json` ist ein versionierter, atomar ersetzter Snapshot einschließlich Profiltexten. `UserDefaults` enthält nur kleine UI-Präferenzen. Vor Schema-Migration lokale Sicherung anlegen; unbekannte neuere Schemata schreibgeschützt behandeln. Beschädigte Daten nicht als leeren Workspace überschreiben. Kein Cloud- oder Synchronisationsdienst.

Anfängliche Schutzlimits: 1 MiB je Profil/Download, 4 MiB bzw. 50.000 Zeilen für die resultierende Systemdatei, 32 MiB für Workspace/JSON-Import, 500 Profile und maximal 16 Ordnerstufen. Downloads bereits während des Streams begrenzen; Headerangaben allein reichen nicht. Limits sind Konstanten mit Tests und verständlichen Fehlermeldungen, keine abgeschnittenen Inhalte. Backups begrenzen, beispielsweise letzte 50 abgeschlossene Transaktionen; Initialbackup, offene Transaktionen und ausdrücklich gesicherte Recoverypunkte ausnehmen. Im Release Speicherverbrauch und Retention dokumentieren.

MacHosts-JSON trägt Schema-Version und exportiert keine App-Autorisierung oder fremden Systemzustand. Importvorschau zeigt Neuanlagen, Namens-/ID-Konflikte und ausgelassene Metadaten. Standard ist append mit neuen IDs und deaktivierten Profilen. Ersetzen des Workspace braucht eine eigene klare Auswahl und vorherige lokale Sicherung. `.hosts`-Export enthält wahlweise Profiltext oder aktivierte Einträge mit sichtbarer Auswahl.

SwitchHosts-Importer sind reine Adapter anhand von Fixtures für ausgewiesene Versionen, nicht ein direkter Zugriff auf die laufende `.SwitchHosts`-Datenablage. Ordner und unterstützte Profiltypen erhalten, Referenzen auflösen, unbekannte Funktionen melden. Gruppen nur dann in lokale Profile auflösen, wenn die Zusammensetzung eindeutig und im Bericht sichtbar ist; Zyklen oder fehlende Referenzen blockieren den betroffenen Import. Kein Import führt Systemwrites oder Remote-Downloads aus.

## Remote, Autostart und Datenschutz

`URLSession` mit normaler TLS-Prüfung, HTTPS, 30 Sekunden Requestlimit, maximal drei Redirects und vier gleichzeitigen Quellen; jede Redirect-URL erneut prüfen. Bei Hostwechsel keine Credentials weiterreichen. Keine `file://`-, HTTP- oder eigenen URL-Schemes. Eine interne Staging-IP ist erlaubt. Kein TLS-Bypass und kein eingebauter Custom-CA-Store.

Source-ID plus Revision nach jedem `await` vergleichen; ein altes Ergebnis darf eine geänderte/gelöschte Quelle nicht wiederherstellen. ETag/Last-Modified berücksichtigen; Offline/Fehler behält den letzten gültigen Stand. Neue gültige Daten sind ein gespeicherter Entwurf, kein Systemwrite. Login-Start ist opt-in, nutzt nach lokalem Nachweis `SMAppService.mainApp` und liest den tatsächlichen OS-Status. Dieser nicht privilegierte Mechanismus ist vom Root-Helper-Thema getrennt.

Logs enthalten ausschließlich Operationen, Fehlerkategorien und zufällige IDs; keine Profile, Domainlisten oder URL-Tokens. Diagnoseexport nur bewusst, mit Vorschau und Redaktion. App Sandbox ist für diesen Zielentwurf nicht vorgesehen; das ist keine Begründung für zusätzliche Entitlements. Hardened Runtime und tatsächlich notwendige Entitlements werden beim Build geprüft und dokumentiert, ohne Account-Abhängigkeit zu erzeugen.
