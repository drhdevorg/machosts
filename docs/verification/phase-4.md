# Phase 4 – Apply, App-Recovery und private Dateitransaktion (Teilabschluss)

Stand: 25. Oktober 2026. **Apply-Koordination, persistente App-Recovery, interne Dateitransaktion und durchgehende private Dateiintegration einschließlich echter Prozessneustarts lokal geprüft. Gate 4 bleibt offen.** Gate 0 ist gemäß [ADR 0002](../decisions/0002-deferred-gate-0.md) zurückgestellt. Phasen 2 und 3 sind lokal bestanden; Clean-Checkout/CI aus Phase 1 bleibt offen.

## Implementiert

- `ApplyCoordinator` serialisiert Vorbereitung, Vorschau, Autorisierung, Commit und Verifikation mit einer ausdrücklichen Sperre über `await` hinweg. Vorbereitung verwendet ausschließlich den gespeicherten Entwurf. Vor der Übergabe an den Commit werden Workspace-Digest, Revision und frisch gelesene Systembytes nochmals geprüft. Der spätere UI-Aufrufer muss seinen Editor/Autosave vorher flushen; ein ungespeicherter Editor ist dem Dienst nicht bekannt.
- Vorschau ist ein unveränderlicher `ApplyPlan`. Zweitklick und parallele Vorbereitung werden zurückgewiesen. Ein No-op braucht weder Autorisierung noch Journalwrite und stellt keinen neuen Receipt aus. Der angewendete Snapshot bleibt vom gewünschten Stand getrennt.
- Der zuletzt bestätigte Blockdigest verhindert stilles Überschreiben eines extern veränderten/entfernten eigenen Abschnitts. Änderungen nur an fremden Bereichen können in eine neue Vorschau einfließen. Ohne bestätigten angewendeten Stand wird ein vorgefundener MacHosts-Block nicht übernommen. Bei alten Receipts ohne separaten Blockdigest gelten konservative Vollvergleichsregeln. Separatoreigentum wird weiterhin nur mit dem bestehenden exakten Digestnachweis verwendet.
- `PendingApply` bindet Transaktions-ID, eingefrorenen Workspace, Workspace-Digest, Vorher-/Nachher-Digest, Blockdigest und Separatornachweis. Die App speichert diese Absicht dauerhaft **vor** dem Commit-Aufruf. Sie ist kein privilegiertes Journal, Backup oder Schreibnachweis. Ein Fehler bei ihrer Speicherung startet keinen Commit.
- Workspace-Schema 2 enthält die offene Absicht. Schema 1 wird nach Validierung und Archivierung der exakten Originalbytes unter einer eindeutigen `workspace.recovery-UUID.json` atomar auf Schema 2 migriert. Generation steigt einmal; Entwurf und Receipt bleiben erhalten. Migrationsfehler führen in einen schreibgeschützten Zustand. Nach Rename-Fehler wird erneut geöffnet, statt einen Ausgang zu behaupten. Unbekannte Schemata werden weiterhin nicht zurückgestuft; ältere Builds lehnen Schema 2 ab.
- Abbruch vor Commit verändert keinen angewendeten Stand. Nach Commit-Beginn führen Timeout, Cancellation, falscher Receipt, abweichender Readback und Fehler beim App-Save zu `recoveryRequired`. Der Dienst löscht eine Absicht nur bei sicherem Nichtbeginn oder nach bestätigtem Abschluss. Ein Cache-Flushfehler bleibt im Receipt getrennt und macht einen bestätigten Write nicht rückgängig.
- Wiederanlauf liest die tatsächlichen Bytes und verlangt den unabhängigen terminalen Transaktionsausgang vom Adapter. Passender Receipt plus Nachher-Digest rekonstruiert den angewendeten Snapshot. Vorher-Digest wird nur zusammen mit autoritativem terminalem Nicht-Commit-Nachweis freigegeben; ein fehlender Receipt allein beweist nicht, dass ein Tool nicht noch schreiben könnte. Fehlende/widersprüchliche Nachweise oder fremde Bytes bleiben gesperrt. Es erfolgt kein automatischer Systemwrite und keine Vollrücksicherung.
- Der Store erhält neuere Entwürfe während des Commit und löst nur die passende Transaktions-ID auf. Eine Laufzeitsperre im Store verhindert parallele Recovery durch einen zweiten Coordinator während des Commit. Der vorhandene Prozesslock verhindert einen zweiten kooperierenden Workspace-Writer. Autosave toleriert Journal-/Receipt-Generationswechsel nur, solange sein bisheriger Entwurfsstand unverändert ist; fremde Entwurfsänderungen werden nicht überschrieben.
- Der interne Integrationsadapter ist ausschließlich für Tests implementiert. Der öffentliche Coordinator verwendet einen unverfügbaren Adapter, der bereits Vorbereitung mit `integrationUnavailable` beendet. App, `SystemWriter` und CLI starten keine Autorisierung und bieten keinen Erfolgssimulations- oder frei wählbaren Zielpfadmodus.

## Tatsächlich verifiziert

Apple Silicon, vorhandene Xcode-27.1-/Swift-6.4-Toolchain, macOS-SDK 27.0. Befehle/Cachepfade entsprechend [ENTWICKLUNG.md](../ENTWICKLUNG.md). Kein Netzwerkabruf.

| Prüfung | Ergebnis |
| --- | --- |
| Gesamtes Swift-Package | bestanden: 29 Services-, 12 Core- und 1 Writer-Sperrtestfunktion, parametrisierte Fälle zusätzlich; `/tmp/machosts-phase4-swift-test.log` |
| Normal-/No-op-/Disableablauf | Bestätigter Stand, No-op ohne Autorisierung/neuen Receipt, bytegenaue Entfernung mit Separatornachweis, externe Änderung erkannt |
| Suspension/Nebenläufigkeit | Zweitklick/Prepare während Autorisierung, Workspace-/Systemmutation während Freigabe, zweiter Coordinator während Commit, neuere Entwürfe und Autosave über Journalgenerationen |
| Abbruch/Fehler | Nutzerabbruch und Task-Cancellation vor Commit; Cancellation nach Commit mit tatsächlich bestätigtem Ausgang; sicherer Nicht-Commit; separater Flushfehler; falscher Receipt und widersprüchlicher Readback |
| Wiederanlauf | offener Intent vor/nach simuliertem Systemcommit, fehlende terminale Nachweise bei Vorher-/Nachher-Bytes, App-Savefehler vor/nach Rename, Wiederöffnung und Receiptabgleich |
| Migration | Schema-1-Fixture mit angewendetem Stand und altem Receipt; bytegenaues Originalarchiv; Abbruch vor/nach Rename; keine leeren Ersatzdaten und keine doppelte Migration |
| Strikte rekursive Formatprüfung | bestanden; `/tmp/machosts-phase4-format.log` |
| Inkrementeller Xcode-Release-Build | bestanden; `/tmp/machosts-phase4-build.log`; benötigter Manifestcachezugriff außerhalb der Coding-Sandbox |

Die Koordinationstests dieses ersten Teilabschlusses halten Systembytes ausschließlich im Speicher und injizieren Autorisierung/Commit/terminale Ergebnisse ausdrücklich. Nur App-Snapshots, Migration und App-Speicherfehlerinjektion laufen auf echten privaten Dateien. Das ist kein Test von Backup, Metadatenübernahme, Rename oder Readback an einer Systemdatei. Die unveränderten Core-Tests sichern zusätzlich Parser-, Konflikt- und Fremdbyteverträge ab. Kein App-/UI-Testlauf in diesem Teilabschluss, da keine Oberfläche verändert wurde.

## Ergänzung: interner Systemtransaktionsvertrag und private Dateien

- `ApplyPlan.replacingManagedBlock` ist die gemeinsame reine Blockoperation für Planung und unabhängige Revalidierung. Akzeptiert wird ausschließlich ein vollständiger eigener Block mit kanonischen LF-Zeilen oder Entfernung; fremde Präfix-/Suffixbytes kommen immer aus dem frisch gelesenen Ziel. Marker, Encoding, Konflikte mit fremden Einträgen und Ergebnislimits werden erneut geprüft. Der Requestadapter normalisiert nur den isolierten erzeugten Block; ursprünglicher Endmarker-Terminator und fremde Bytes bleiben erhalten.
- `SystemTransactionRequest` ist ein interner **In-Process-Vertrag**, kein privilegiertes JSON-/IPC-Protokoll. Er bindet Version, Transaktions-ID, Vorher-/Nachher-Digest, bisherigen Blockdigest und typisierte Blockmutation. Keine Pfade, Shellsyntax, Workspace-Daten oder fremden Ersatzbytes. Er stellt weder Autorisierung noch einen Besitznachweis für einen bisher fremden Block dar; die vorgelagerte Bestätigung bleibt erforderlich.
- `FileTransaction` verlangt einen exklusiven synchronen Dateiadapter. Vor einem Write werden alle gespeicherten Journale und zugehörigen Backups geprüft; Replay und offene Transaktionen sperren weitere Writes. No-op erzeugt weder Backup noch Journal/Receipt. Originalbytes und unterstützte Metadaten werden vor dem vorbereiteten Journal unabhängig gespeichert und zurückgelesen. Erst danach folgen Identitäts-/Revisionsprüfung, Rename, Readback und terminaler Receipt. Cache-Flush bleibt `notAttempted`.
- `PrivateTransactionFiles` existiert ausschließlich im Testtarget. Er erstellt selbst ein neues privates temporäres Verzeichnis; kein frei konfigurierbares Ziel. Deskriptorrelative Zugriffe, `O_NOFOLLOW`, reguläre Einzel-Link-Dateien, Benutzerbesitz, Modus 0600, begrenzte Reads, mtime/ctime, `flock`, exklusive Tempfiles, `fsync` und `renameat` werden tatsächlich ausgeführt. Symlink, Hardlink, FIFO, Verzeichnis, offene Rechte, Flags, ACLs und fremde xattrs werden abgewiesen. Das lokal automatisch vorhandene `com.apple.provenance` wird begrenzt gelesen, im Backup erfasst und beim Ersatz bytegenau verglichen; ein abweichender Wert stoppt den Ersatz. Die Fixture unterstützt keine allgemeine Metadatenmigration.
- Wiederanlauf liest Journale/Backups erneut von privaten Dateien und vergleicht aktuelle Bytes und Metadaten. Vorher-Bytes schließen eine vorbereitete Transaktion als Nicht-Commit ab; Nachher-Bytes werden vor einem rekonstruierten Receipt nochmals synchronisiert und gelesen. Fehlende, fremde oder widersprüchliche Nachweise bleiben unbekannt/gesperrt. Recovery schreibt keine Backupbytes zurück. Historische terminale Journale erhalten Separatorbeweise auch nach einer abgebrochenen Folgetransaktion.

### Tatsächlich ausgeführte ergänzende Prüfungen

Gleiche lokale Toolchain und Befehlsfolge wie oben; alle Dateiwrites ausschließlich in neu erstellten privaten Fixtures. Die zwei versehentlich gleichzeitig laufenden Coding-Chats wurden auf Nutzerfreigabe abgestimmt; nur eine Implementierung ist im aktiven Package, die verworfenen Varianten liegen separat unter `/tmp`.

| Prüfung | Ergebnis |
| --- | --- |
| Gesamtes Swift-Package | bestanden: 14 System-, 29 Services- und 12 Core-Testfunktionen, parametrisierte Fälle zusätzlich; `/tmp/machosts-phase4-transactions-test.log` |
| Dateitransaktion | Backup/Readback, No-op, Replay, Apply/Disable, exakter Fremdbyteerhalt, Separatorbesitz nach abgebrochener Folgetransaktion |
| Unterbrechungen | injizierte Fehler bei Backup, vor Journalpublikation, vor/nach Ziel-Rename, bei Readback und vor Receiptpublikation; erneuter Abgleich gesicherter Dateien |
| Revisions-/Integritätsgrenzen | externe Bytes vor Rename, gleiche Bytes mit neuer Dateiidentität, beschädigter Backup, falscher Receipt, externe Änderung nach Commit, offenes Journal blockiert neuen Request |
| Request-/Dateiformat | unbekannte Version, stale Digest, nicht isolierter/ungültiger/übergroßer Block, deaktivierte Profilsyntax, Konflikte, unbestätigter vorhandener Block, kaputte Marker/Encoding; LF/CRLF/CR/fehlender Endterminator |
| Private Dateigrenze | Symlink/Hardlink, FIFO/Verzeichnis, unsichere Rechte, zusätzlicher xattr, echte ACL und zweite Locksitzung abgewiesen |
| Strikte rekursive Formatprüfung | bestanden; `/tmp/machosts-phase4-transactions-format.log` |
| Abschließender inkrementeller Xcode-Release-Build | bestanden; `/tmp/machosts-phase4-transactions-build.log`; erforderlicher Manifestcachezugriff außerhalb der Coding-Sandbox |

Anfängliche Prüfungen scheiterten durch die parallelen Dateien, Swift-Typkonvertierungen und die zunächst zu strikte Behandlung des automatisch vorhandenen macOS-Provenance-xattrs. Diese Ursachen sind korrigiert; die Tabelle nennt den abschließenden erfolgreichen Stand. Die Testsession simuliert Unterbrechungen durch geworfene Fehler unter exklusiv gehaltenem Lock und erneutes Öffnen der Datendateien. In diesem damaligen Teilabschluss wurde kein echter Prozessabbruch, Stromverlust, Kernel-/Datenträger-Durabilitynachweis oder privilegierter Neustart durchgeführt. Der Lock wurde damals mit zweitem unabhängig geöffnetem Descriptor geprüft; der folgende Teilabschluss ergänzt tatsächlich getrennte Prozesse. UI-Tests wurden nicht wiederholt; Oberfläche unverändert.

## Ergänzung: durchgehende Dateiintegration und echte Prozessneustarts

`CoordinatorFileIntegrationTests.swift` verbindet den tatsächlichen `ApplyCoordinator` und `WorkspaceStore` über einen ausschließlich im Testtarget definierten Actor mit `FileTransaction` und `PrivateTransactionFiles`. App, CLI und Produktionsschnittstellen bleiben unverändert gesperrt. Die Fixture kann ihr selbst erstelltes privates temporäres Verzeichnis unter erneuter Verzeichnis-/Datei-/Lockprüfung wieder öffnen. Es gibt keinen Produkt-Testmodus und keinen auswählbaren Systemzielpfad.

Der Normalablauf prüft Apply → bestätigten Snapshot → No-op ohne erneute Autorisierung → Disable mit bytegenauer Wiederherstellung der fremden Bytes inklusive fehlendem Endterminator. Das ursprüngliche Backup wird über den Dateiadapter unabhängig gelesen.

Die Prozessmatrix startet für jeden Fall einen eigenen Testprozess, der an der festgelegten Grenze mit `_exit(86)` ohne Swift-Deinitialisierung endet. Der Elternprozess verlangt genau Exit 86 und einen persistierten offenen App-Intent ohne angewendeten Snapshot. Ein **weiterer neuer Prozess** öffnet Workspace und Dateisitzung und führt den echten Koordinatorabgleich aus:

| Abbruchpunkt | Nachweis und erwarteter Wiederanlauf |
| --- | --- |
| Commit-Eintritt nach gespeichertem App-Intent | Kein Systemjournal; weiterhin `recoveryRequired` |
| Vor Backup-Publikation | Kein Systemjournal; weiterhin `recoveryRequired` |
| Vor vorbereitetem Journal, nach gespeichertem/zurückgelesenem Backup | Backup allein genügt nicht; weiterhin `recoveryRequired` |
| Vor Ziel-Rename, nach dauerhaftem vorbereitetem Journal | Vorher-Bytes plus exklusiver Journalabgleich ergeben terminales Nicht-Commit; App-Intent wird aufgelöst |
| Direkt nach Ziel-Rename, vor Verzeichnissynchronisierung | Nachher-Bytes werden synchronisiert und gelesen; Receipt wird rekonstruiert und App-Snapshot bestätigt |
| Nach Rename/Verzeichnissynchronisierung, vor Adapter-Readback | Nachher-Bytes und Journal bestätigen den Commit beim Wiederanlauf |
| Vor terminaler Receipt-Publikation | Readback und Journal erlauben Receipt-Rekonstruktion |
| Nach terminalem Receipt, vor Rückkehr an den Koordinator/App-Save | Persistierter Receipt bestätigt den angewendeten Snapshot |

Bestätigte Fälle werden im Recoveryprozess nochmals abgeglichen und anschließend bewusst deaktiviert; die ursprünglichen fremden Bytes bleiben exakt erhalten. Unbekannte Fälle behalten ihren Intent und blockieren eine neue Vorschau. Ein fehlendes Journal wird auch bei unveränderten Vorher-Bytes nicht zu einem erfundenen Nicht-Commit umgedeutet. Eine spätere enge Protokolllösung für diese verwaisten App-Intents bleibt offen.

Zusätzliche neue Prozesse prüfen nach einem Abbruch hinter Rename fremde Zielbytes sowie einen noch dekodierbaren, aber digestwidrig veränderten Backup. Der Koordinator bleibt gesperrt und verändert weder Zielbytes noch App-Snapshot. Ein tatsächlich unabhängiger Kindprozess wird sowohl am Dateitransaktionslock als auch am Workspace-Lock abgewiesen.

### Tatsächlich ausgeführte Prüfungen dieses Teilabschlusses

- Gesamtes Swift-Package bestanden: **19 System-, 29 Services- und 12 Core-Testfunktionen**, parametrisierte Fälle zusätzlich; `/tmp/machosts-phase4-process-test.log`. Die fünf neuen System-Testfunktionen umfassen einen Worker-Einstieg ohne Aktion im normalen Lauf. Die Prozessprüfungen starten insgesamt 21 Kindprozesse: acht Abbruch-/Recoverypaare, zwei beschädigte/externe Abbruch-/Recoverypaare und eine Locksitzung.
- Strikte rekursive Formatprüfung einschließlich UI-Tests bestanden: `/tmp/machosts-phase4-process-format.log`.
- Nur Testdateien und Dokumentation geändert; kein erneuter Xcode-App-Build oder UI-Testlauf. Das Swift-Package wurde mit den neuen Testdateien inkrementell gebaut.
- Anfängliche Prüfläufe scheiterten am Testentwurf mit Revision 0 und am Test-Runnermanagement. Der Worker startet jetzt den bereits aktiven `swiftpm-testing-helper` direkt mit dem aktuellen Testbundle, statt rekursiv SwiftPMs gesperrtes Buildverzeichnis zu verwenden. Asynchrones Beobachten des Kindprozesses ersetzt das festhängende `waitUntilExit`; Deadline und Abbruchbereinigung sind enthalten. Der fokussierte Reparaturlauf und anschließend das gesamte Package bestanden.

Die Prozesssuite setzt den lokalen SwiftPM-Test-Runner der dokumentierten Toolchain voraus; Ausführung über einen anderen Runner ist nicht nachgewiesen. `_exit` belegt Prozessverlust und Lockfreigabe, keinen Stromverlust, SIGKILL während eines Syscalls, Kernel-Crash oder Datenträger-Durability. In diesem damaligen Teilabschluss liefen App und Dateitransaktion im Worker gemeinsam; die folgende Ergänzung prüft getrennte unprivilegierte Prozesse. Ein privilegiertes Tool bleibt ungetestet.

## Ergänzung: App-Snapshot-Abbruch und unabhängige Worker-Lebensdauer

`ProcessLifecycleTests.swift` ergänzt die vorhandene Prozessumgebung; der gemeinsame Diskadapter und Runner werden wiederverwendet. Produktcode und produktive Schreibgrenze sind unverändert. Alle Ziele liegen in neu erstellten privaten Fixtureverzeichnissen. Der Testtransport enthält nur eine erste Blockmutation und deren Digests/ID; er existiert ausschließlich im Testbundle und ist weder ein freigegebenes IPC-Protokoll noch ein privilegierter Eingang.

### App-Publikationsmatrix

Neun Fälle beenden einen tatsächlichen App-/Recovery-Testprozess mit `_exit(86)` an den vorhandenen `WorkspaceFiles`-Fehlerpunkten. Ein weiterer neuer Prozess öffnet die Daten und prüft den Koordinatorabgleich, den erhaltenen Entwurf, die offene Absicht, den angewendeten Snapshot sowie die unveränderten Zielbytes:

| App-Save | Vor Temp-Inhalt / vor Rename | Nach Rename, vor Verzeichnis-fsync |
| --- | --- | --- |
| Absicht vor Commit | Alter Entwurf ohne Absicht bleibt gültig; keine Zieländerung, Zustand unbestätigt | Absicht vorhanden, kein Systemjournal; weiterhin Recovery erforderlich |
| Bestätigter Commit | Absicht bleibt vorhanden, terminaler Dateireceipt rekonstruiert den angewendeten Snapshot | Angewendeter Snapshot bereits vorhanden; erneuter Abgleich bestätigt ihn |
| Rekonstruierter Commit beim Wiederanlauf | Erneuter Prozess kann den Receipt nochmals zuordnen und den App-Save abschließen | Rekonstruktion bereits publiziert; erneuter Abgleich bleibt idempotent |

Die Prüfung erwartet den jeweils exakten Absichts-/Snapshotzustand schon **vor** Recovery. Unbekannte Fälle bleiben gesperrt; abgeschlossene Fälle erlauben einen wiederholten Abgleich. Ein nach Rename beendeter Prozess beweist keine Persistenz bei Stromverlust.

### Getrennte App- und Workerprozesse

Vier Fälle kombinieren eine Workerpause vor bzw. nach dem Ziel-Rename mit anschließendem normalem Abschluss bzw. `SIGKILL`. Der App-Testprozess startet einen eigenständigen Worker. Dieser hält ausschließlich den Dateitransaktionslock und pausiert nach dauerhaft gespeichertem vorbereitetem Journal. Die App speichert währenddessen einen neueren Entwurf und endet mit `_exit(86)`; der Worker läuft weiter. Ein neu gestarteter App-/Recoveryprozess öffnet erfolgreich den nun freigegebenen Workspace, während der separate Workerlock weiterhin belegt ist.

Der Testadapter liefert bei belegtem Workerlock ausdrücklich einen unbekannten Ausgang. Recovery bleibt sowohl mit Vorher- als auch sichtbaren Nachher-Bytes gesperrt, verändert weder App-Snapshot noch Zielbytes und erlaubt keine neue Vorschau. Erst nach Workerabschluss bzw. dessen gezieltem Prozessende und tatsächlicher Lockfreigabe startet ein weiterer Recoveryprozess:

- Abschluss bestätigt den unabhängigen terminalen Receipt.
- `SIGKILL` vor Rename ergibt unter exklusivem Journalabgleich Nicht-Commit.
- `SIGKILL` nach Rename erlaubt synchronisierten Readback und Receipt-Rekonstruktion.
- In allen Fällen bleibt der neuere gespeicherte Entwurf erhalten. Der angewendete Stand bezieht sich ausschließlich auf den eingefrorenen älteren Workspace und die richtige Transaktions-ID. Eine anschließende Vorschau verwendet die neuere Revision.

Workerpausen, Unterprozesslaufzeit und Lockwartezeit sind begrenzt; Fehlerpfade beenden verbliebene Worker. Testlogs werden bei unerwartetem Recoveryprozessfehler ausgegeben. Die normalen Package-Läufe betreten den Worker-Einstieg ohne Umgebungsauftrag nicht.

### Tatsächlich ausgeführte Prüfungen dieses Teilabschlusses

- Gesamtes Swift-Package bestanden: **22 System-, 29 Services- und 12 Core-Testfunktionen**, parametrisierte Fälle zusätzlich; `/tmp/machosts-phase4-lifecycle-test.log`. Die drei neuen Testfunktionen prüfen neun App-Publikationsabbrüche und vier unabhängige App-/Worker-Lebenszyklen. Zusammen mit der bestehenden Suite werden 58 Kind-/Nachfolgeprozesse gestartet, davon vier eigenständig fortlaufende Worker.
- Strikte rekursive Formatprüfung einschließlich App und UI-Tests bestanden; `/tmp/machosts-phase4-lifecycle-format.log`.
- Erster Gesamtlauf mit sechs App-Savefällen und vier Workerfällen bestanden; nach Ergänzung der drei Recovery-Savefälle und gemeinsamer Adapternutzung abschließender Gesamtlauf ebenfalls bestanden. Keine Laufzeitkorrektur im Produktcode erforderlich.
- Ausschließlich Testdateien und Dokumentation geändert. Das Package einschließlich neuer Tests wurde inkrementell gebaut; kein erneuter Xcode-App-Build, UI-Test oder privilegierter Testlauf.

Diese Tests belegen reale Prozessverluste, voneinander unabhängige unprivilegierte Lebenszyklen und die Koordinator-/Dateiverträge an privaten Fixtures. Sie belegen keine sichere Toolherkunft, OS-Autorisierung, produktive IPC-Integrität, Stromverlustbeständigkeit oder VM-Systemintegration. Gate 4 bleibt offen.

## Ergänzung: unprivilegierte Dateibeobachtung

`SystemFileMonitor` in `HostsServices` bietet einen ausschließlich lesenden, ereignisgesteuerten `AsyncStream`. Der öffentliche Konstruktor verwendet fest `/private/etc/hosts`; der interne Testkonstruktor wird ausschließlich mit privaten Fixtures verwendet. Die App startet den Dienst noch nicht. Der produktive Apply-Adapter, das CLI und der Systemwriter bleiben unverfügbar.

- Ein Dispatch-Dateisystemsignal auf dem Elternverzeichnis erkennt wiederholten atomaren Ersatz, Löschung und Neuerstellung. Zusätzlich wird der aktuelle Datei-Inode beobachtet, damit Änderungen ohne Rename erfasst werden. Vor jedem Read wird dessen Beobachtung erneuert. Ereignisse werden entprellt; identische Digests erzeugen keine erneute Meldung, auch bei Ersatz mit gleichen Bytes oder fremden Verzeichnisereignissen. Es gibt keinen Pollingtimer.
- Datei-I/O läuft auf dem Dienstactor außerhalb des Main Actor. Deskriptorrelative Reads verwenden `O_NOFOLLOW`, `O_NONBLOCK` und `O_CLOEXEC`, prüfen reguläre Einzel-Link-Dateien, begrenzen während des Lesens auf 4 MiB und gleichen Dateiidentität, Länge und mtime/ctime nach dem Read ab. Der Dienst gibt ausschließlich Digest oder typisierten Lesefehler aus, keine Profilinhalte oder Dateipfade in Logs. Er besitzt keine Schreiboperation.
- Verlust, Umbenennung oder Widerruf des beobachteten Elternverzeichnisses ergibt `watchUnavailable`. Der Dienst behauptet anschließend auch bei erfolgreicher manueller Pfadauflösung keine funktionierende Beobachtung; ein ausdrückliches `start()` registriert neu. `refresh()` ermöglicht einen frischen Abgleich etwa nach Wake oder bestätigtem Apply.
- Der Stream puffert nur die neueste Beobachtung. Stop, Ersatz einer Subscription und generationsgebundene Termination beenden alte Beobachtungen; Dispatch schließt die Descriptoren erst nach Source-Cancellation. Mutex schützt die Source-Lebensdauer ohne unkontrollierte Sendable-Ausnahme.
- `SystemFileObservation.status` vergleicht einen lesbaren Digest mit dem separat bestätigten Receipt-Digest. Fehlender Receipt oder Lesefehler ergibt keinen bestätigten Stand; Abweichungen ergeben `externalChange`. Eine offene App-Absicht bleibt immer `recoveryRequired`, auch bei passenden Vorher-/Nachher-Bytes. Beobachtung löst keine Absicht auf und erzeugt keinen Receipt. Der spätere UI-Aufrufer muss den expliziten Lesefehler anzeigen und den Vergleich auch bei geändertem Receipt neu berechnen.

### Tatsächlich ausgeführte Prüfungen dieses Teilabschlusses

Gleiche lokale Toolchain und Cachepfade wie in [ENTWICKLUNG.md](../ENTWICKLUNG.md); ausschließlich private temporäre Dateiziele.

| Prüfung | Ergebnis |
| --- | --- |
| Sechs neue Vertragstests | Wiederholter atomarer Ersatz, bytegleicher Ersatz, fremde Verzeichnisereignisse, Löschung/Neuerstellung, Änderungen im selben Inode, Entprellung von 20 Änderungen, Symlink/Hardlink, Übergröße, Erholung, verlorenes Elternverzeichnis mit explizitem Neustart, Subscriptionwechsel/Stop und konservativer Receipt-/Intentvergleich bestanden |
| Gesamtes Swift-Package | **22 System-, 35 Services- und 12 Core-Testfunktionen bestanden**, parametrisierte Fälle zusätzlich; `/tmp/machosts-monitor-test.log` |
| Strikte rekursive Formatprüfung | bestanden einschließlich App und UI-Tests; `/tmp/machosts-monitor-format.log` |
| Inkrementeller Xcode-Release-Build | bestanden; `/tmp/machosts-monitor-build.log`; benötigter Benutzer-Manifestcachezugriff außerhalb der Coding-Sandbox |

Der erste Build fand einen nicht verfügbaren Gleichheitsoperator für POSIX-Zeitstempel; der Vergleich prüft nun Sekunden und Nanosekunden. Der erste Paketlauf zeigte außerdem, dass eine reine Verzeichnisbeobachtung Änderungen im selben Inode nicht erfasst. Die zusätzliche Dateibeobachtung behebt dies; fokussierter Reparaturlauf und abschließender Gesamtlauf bestanden. Der erste Xcode-Aufruf scheiterte am bekannten Sandbox-Manifestcachezugriff; der freigegebene Wiederholungslauf bestand. Keine UI-Tests, Sleep/Wake-Abnahme, OS-Permissionfehlermatrix oder echte Systemdateibeobachtung ausgeführt. Die Hosts-Datei des Arbeitsrechners wurde auch für diese Tests weder gelesen noch verändert. Die Dienstimplementierung ersetzt keine UI-Anbindung und keinen Gate-4-Integrationsnachweis.

## Ergänzung: App-Anbindung der Dateibeobachtung

Die native Startansicht verwendet jetzt `SystemObservationModel` aus HostsServices. Das `@MainActor @Observable`-Modell hält ausschließlich den aktuellen Lesestatus und die Vergleichsdaten des Workspace. Es erzeugt keine Receipts, ändert keine Systembytes und löst keine Apply-Absicht auf. Die Darstellung ist im String Catalog deutsch/englisch hinterlegt.

- Der App-weite `AppModel` startet eine gemeinsame Beobachtung für alle Fenster. `WorkspaceStore.openDefault()` öffnet den Standard-Workspace außerhalb des UI-Actors und hält dessen exklusiven Prozesslock für die App-Lebensdauer. Bestehende Schema-/Recoveryregeln gelten unverändert. Ein Öffnungsfehler wird sichtbar; „Erneut prüfen“ kann den Start wiederholen, ohne einen leeren Workspace als Ersatz zu speichern.
- Lesbare Digests werden mit dem separat gespeicherten Receipt abgeglichen. Ein neuer Receipt oder Workspacezustand berechnet die Anzeige auch ohne neues Dateiereignis neu. Fehlender, nicht verfügbarer oder schreibgeschützter Workspace und Lesefehler erlauben keine Bestätigung. Eine bekannte offene Absicht hat immer Vorrang als `recoveryRequired`, auch bei passenden Bytes, Lesefehlern oder gestoppter Beobachtung.
- Die Oberfläche zeigt konkrete Lesefehler, externen Änderungsstatus und unbestätigten Zustand. „Erneut prüfen“ fordert einen Read an; „Beobachtung neu starten“ ersetzt die Subscription einschließlich verlorener Verzeichnisbeobachtung. `NSWorkspace.didWakeNotification` ist mit erneutem Lesen verbunden. Keine Pollingschleife und keine Autorisierung.
- Stream-Konsum bleibt asynchron. Generationen schützen gegen veraltete Fortsetzungen bei Austausch der Beobachtung; Cancellation beendet die Subscription und hebt einen zuvor bestätigten aktuellen Status auf. Das Schließen eines einzelnen Fensters beendet die App-weite Task nicht. Native Lebenszyklusabnahme bleibt gesondert offen.

### Tatsächlich ausgeführte Prüfungen dieses Teilabschlusses

| Prüfung | Ergebnis |
| --- | --- |
| Gesamtes Swift-Package nach Implementierung | **22 System-, 38 Services- und 12 Core-Testfunktionen bestanden**, parametrisierte Fälle zusätzlich; `/tmp/machosts-observation-app-test.log` |
| Abschließende vier Modell-Vertragstests | bestanden nach Ergänzung des persistierten Intentnachweises und Startfehler-/Neustartfalls; `/tmp/machosts-observation-app-focused.log` |
| Strikte rekursive Formatprüfung | bestanden einschließlich App und UI-Tests; `/tmp/machosts-observation-app-format.log` |
| Abschließender inkrementeller Xcode-Release-Build | bestanden; `/tmp/machosts-observation-app-build.log` |

Die vier Modelltests prüfen Receiptwechsel ohne Dateiereignis, unbekannten/schreibgeschützten Workspace, externe Änderungen, Löschung/Neuerstellung, Lesefehler, Recoveryvorrang, Startfehler mit Neustart, Verlust des Verzeichniswatches, Ersatz einer laufenden Subscription und Cancellation. Ein tatsächlicher privater Workspace hält einen persistierten offenen Intent; die Beobachtungen lassen Snapshot und gespeicherte Workspacebytes unverändert. Die abschließend ergänzte vierte Testfunktion wurde fokussiert ausgeführt; keine unveränderte Gesamtsuite erneut gestartet.

Der erste Xcode-Aufruf scheiterte am bekannten Sandboxzugriff auf den Benutzer-Manifestcache. Der freigegebene Build und der abschließende Build nach Ergänzung des Workspace-Neuversuchs bestanden. Keine App gestartet, keine UI-Tests, keine echte Systemdateibeobachtung, keine native Mehrfenster-/Sleep-/Wake-Abnahme und keine VM-Tests ausgeführt. Der Standard-Workspacepfad wurde im Testlauf nicht geöffnet; alle Datei-/Workspace-Schreibtests verwendeten private Fixtures. Die Hosts-Datei des Arbeitsrechners wurde weder gelesen noch verändert. Gate 4 und die vollständige Haupt-App aus Phase 5 bleiben offen.

## Ergänzung: verwaiste App-Absichten und gemeinsame Recovery-Sperre

Fehlende Systemjournale werden jetzt vom internen Transaktionskern als `missingJournal` zurückgegeben, getrennt von `unknown` und einem belegten `notCommitted`. Der Koordinator unterscheidet außerdem `workerActive`. Weder ein leerer Journalbereich noch passende Vorher-/Nachher-Bytes erlauben das Löschen einer App-Absicht oder das Erfinden eines Receipts. Eine verlorene Journaldatei nach tatsächlichem Fixture-Commit wird deshalb genauso konservativ behandelt wie ein Abbruch vor Erstellung des Journals.

- `ApplyRecoveryAssessment` hält den letzten Abgleich als flüchtigen Diagnosewert: Transaktions-ID, Dateivergleich und Art des unabhängigen Nachweises. Keine Systembytes, Profiltexte oder neue persistente Schemas. Fehlender Nachweis, aktiver Worker, unbekannter Ausgang, nicht verfügbare Prüfung und ungültiger Receipt sind ausdrücklich verschieden. Ein gültiger Receipt wird auch bei abweichenden Istbytes gegen die Absicht validiert; zum Auflösen sind weiterhin gültiger Receipt **und** frischer Nachher-Digest nötig. Ein belegter Nicht-Commit benötigt frische Vorher-Bytes. Lesefehler oder Cancellation erhalten die Absicht.
- `WorkspaceStore.claimApplyRecovery` serialisiert den gesamten Recoveryabschnitt über alle Koordinatoren desselben Stores. Die bisherige Prüfung auf laufendes Apply allein ließ zwei Recoveryaufrufe durch getrennte Koordinatoren gleichzeitig zu. Die neue Sperre umfasst sämtliche `await`-Punkte und wird nach Erfolg, Fehler und Cancellation freigegeben. Neuere Entwürfe bleiben währenddessen speicherbar und werden beim Auflösen erhalten. Der Workspace-Prozesslock und der unabhängige Workerlock bleiben zusätzlich nötig.
- `SystemObservationModel.pendingFileState` stellt den Vergleich mit der gespeicherten Absicht ohne Auflösung bereit. Die deutsche/englische Oberfläche zeigt Vorher-, Ziel-, abweichenden oder nicht aktuell lesbaren Stand und erklärt, dass dieser Build die Systemtransaktionsnachweise nicht prüfen kann. Ein beendeter Monitor darf keinen aktuellen Dateivergleich behaupten. Die Oberfläche behauptet mangels produktivem Adapter insbesondere nicht, dass tatsächlich ein Journal fehlt.
- Verwaiste Absichten bleiben erhalten und neue Übernahmen gesperrt. Es gibt keine „trotzdem verwerfen“-Aktion und keinen Wiederholungswrite. Ein zukünftiger Auflösungsweg benötigt eigene persistente, replaygeschützte Evidenz und einen nachgewiesenen Ausschluss noch laufender Worker. Dieser Teil ist ausdrücklich offen; Diagnose ersetzt diesen Protokollnachweis nicht.

### Tatsächlich ausgeführte Prüfungen dieses Teilabschlusses

Gleiche lokale Toolchain und Cachepfade wie in [ENTWICKLUNG.md](../ENTWICKLUNG.md); ausschließlich private Dateiziele.

| Prüfung | Ergebnis |
| --- | --- |
| Gesamtes Swift-Package | **23 System-, 43 Services- und 12 Core-Testfunktionen bestanden**, parametrisierte Fälle zusätzlich; `/tmp/machosts-orphan-test.log` |
| Nachträglich ergänzte Nachweise | **Zwei zusätzliche Services-Testfunktionen bestanden**: erneutes Öffnen mit älterem Receipt und neuerem Entwurf in drei Dateiständen sowie unverfügbarer Produktionsadapter bei offener Absicht; `/tmp/machosts-orphan-focused.log` |
| Strikte rekursive Formatprüfung | bestanden; `/tmp/machosts-orphan-format.log`; abschließend nach den zusätzlichen Tests erneut geprüft |
| Inkrementeller Xcode-Release-Build | bestanden; `/tmp/machosts-orphan-build-approved.log` |

Die neue Services-Matrix deckt sieben Evidenzarten in jeweils drei Dateiständen ab (21 Fälle). Weitere Fälle prüfen Fehler beim ersten/abschließenden Read, konkurrierende Koordinatoren, während des Nachweis-Await geänderte Systembytes und Entwürfe sowie Cancellation mit anschließendem erfolgreichen Neuversuch. Die Systemtests prüfen verlorene Journale nach tatsächlichem privaten Commit mit Vorher-/Nachher-Bytes einschließlich unveränderter Zielmetadaten und Artefakte. Die bestehenden unabhängigen Crash-/Recoveryprozesse prüfen jetzt zusätzlich ausdrücklich `missingJournal` vor Journalerstellung und `workerActive` bei gehaltenem Prozesslock. Der Beobachtungsmodelltest deckt alle vier Dateivergleichszustände ab und prüft unveränderte persistierte Workspacebytes.

Der erste Xcode-Aufruf scheiterte am bekannten Sandboxzugriff auf den Benutzer-Manifestcache. Der freigegebene Wiederholungslauf bestand. Die ergänzten zwei Tests liefen danach gezielt; keine unveränderte Gesamtsuite und kein App-Build für reine Test-/Dokumentationsergänzungen erneut gestartet. Im Release-Build keine Warnung aus eigenem Swift-Code; Xcodes AppIntents-Metadatenextraktion meldet mangels entsprechender Frameworkabhängigkeit ihren ausgelassenen Schritt. Keine App gestartet, keine UI-/Wake-/VM-Tests und keine Systemautorisierung ausgeführt. Standard-Workspace und Hosts-Datei des Arbeitsrechners einschließlich Rechte/Metadaten blieben unangetastet. Gate 0, Gate 4 und native UI-Abnahme bleiben offen.

## Ergänzung: dauerhafte Stilllegung journal-loser App-Absichten

[ADR 0003](../decisions/0003-orphan-retirement.md) beschreibt den neuen internen Vertrag. Eine explizit angeforderte Stilllegung persistiert unter demselben Prozesslock wie Commit einen `ApplyRetirement`-Eintrag. Version, Transaktions-ID, Vorher-/Nachher-Digest und Workspace-Digest binden ihn vollständig an die App-Absicht. Jeder spätere Commit derselben ID wird vor Backup/Journal/Zielwrite als Replay abgewiesen, auch mit geänderten Requestdaten. Ein noch laufender Worker verhindert die Stilllegung. Die Sperreinträge bleiben nach App-Auflösung erhalten.

Die Stilllegung ist **kein historischer Nicht-Commit und kein Receipt**. Ein früherer Commit mit verlorenem Journal und inzwischen wiederhergestellten Vorher-Bytes wird ausdrücklich als eigener Testfall behandelt. Vorhandene Journale, andere vorbereitete Transaktionen, Nachher-/Fremdbytes, beschädigte Nachweise und Lesefehler verhindern den Vorgang. Ein identischer Sperreintrag kann erneut abgeglichen werden; andere Bindungen derselben ID und Widersprüche zwischen Journal und Sperreintrag blockieren. Zielbytes und deren Metadaten bleiben unverändert.

Die App hält ihre gemeinsame Recovery-Sperre über Stilllegung und unabhängigen anschließenden Abgleich. Nur vollständig passende Stilllegung plus nach dem Nachweis frisch gelesener Vorher-Digest löst die Absicht auf. Älterer angewendeter Snapshot und neuerer Entwurf bleiben erhalten, Ergebnis `unconfirmed`, kein neuer Receipt. Nachher-/Fremdbytes, Cancellation und Fehler erhalten die Absicht. Nach einem Fehler kann die Stilllegung trotzdem bereits dauerhaft gespeichert sein und verhindert dann weiterhin verspätete Commits. Recovery synchronisiert einen bereits sichtbaren Sperreintrag samt Verzeichnis nochmals, bevor sie terminale Evidenz zurückgibt; damit wird der Prozessabbruch zwischen Rename und Verzeichnis-Sync berücksichtigt.

Nur private Testadapter implementieren diesen Ablauf. Die Koordinatormethode ist intern; Standardadapter wirft `integrationUnavailable`. Keine neue UI-Aktion, kein CLI-Schalter, kein produktiver Autorisierungs-/Systemadapter und keine Workspace-Schemaänderung. Die vorangehende Beschreibung des gesperrten Produktionszustands gilt weiterhin. Der hier beschriebene Fixture-Vertrag löst den vormals offenen internen Protokollentwurf ab; der privilegierte Transport-/Persistenznachweis bleibt offen.

### Tatsächlich ausgeführte Prüfungen dieses Teilabschlusses

Gleiche lokale Toolchain und Cachepfade wie in [ENTWICKLUNG.md](../ENTWICKLUNG.md); ausschließlich private Datei-/Workspaceziele.

| Prüfung | Ergebnis |
| --- | --- |
| Gesamtes Swift-Package | **29 System-, 48 Services- und 12 Core-Testfunktionen bestanden**, parametrisierte Fälle zusätzlich; `/tmp/machosts-retirement-test.log` |
| Systemsuite nach Ergänzung der Recovery-Persistenzprüfung | **30 System-Testfunktionen bestanden**, einschließlich aller bisherigen Prozessfälle und sieben neuer Stilllegungsabbrüche; `/tmp/machosts-retirement-system-final.log` |
| Nachträglicher geänderter Replay-Request | Zwei parametrisierte Fälle der vorhandenen Stilllegungs-/Replay-Testfunktion bestanden; `/tmp/machosts-retirement-replay-final.log` |
| Strikte rekursive Formatprüfung | bestanden einschließlich App und UI-Tests; `/tmp/machosts-retirement-format.log` |
| Inkrementeller Xcode-Release-Build | bestanden; `/tmp/machosts-retirement-build-approved.log` |

Die neue Prozessmatrix beendet eigenständige Prozesse vor dem Sperreintrag, vor/nach dessen Rename, nach dessen Persistenz sowie vor App-Write, vor/nach App-Rename. Separate Recoveryprozesse lösen anschließend mit unabhängiger Evidenz auf; weitere unabhängige Prozesse versuchen den verspäteten ursprünglichen Request und werden abgewiesen. Die bestehende App-/Worker-Lebenszyklusmatrix prüft zusätzlich die verweigerte Stilllegung bei aktivem Worker vor/nach Ziel-Rename. Keine Kennzeichnung eines belegten Workerlocks als terminaler Ausgang.

Weitere Systemfälle prüfen vorher ungestartete und tatsächlich ehemals committete Transaktionen, idempotente Stilllegung, neue unabhängige Transaktionen, externe Mutation während Stilllegung, fehlgeschlagenen Save vor/nach Persistenz, verweigerten Persistenzabschluss, kaputte/neuere/falsch benannte Sperreinträge, Bindungskonflikte und Journalwidersprüche. Die Services-Evidenzmatrix umfasst nun neun Evidenzarten in drei Dateiständen (27 Fälle). Zusätzlich geprüft: ältere Receipts/neuere Entwürfe, unzulässige Transaktions-ID, konkurrierende Koordinatoren, Entwurfsänderungen während Stilllegung, nachträgliche Zielbytes, Lesefehler, Cancellation und unverfügbarer Produktionsadapter. Die gemeinsame Recovery-Sperre wird auch bei Fehlern freigegeben.

Der erste Gesamtlauf fand einen Fehler im neuen Negativtest: Dessen Folgeplan war ein No-op, aus dem keine App-Absicht erzeugt werden darf. Der Test verwendet nun einen expliziten Request zur Prüfung der gesperrten Dateigrenze; der anschließende Gesamtlauf bestand. Bei der Abschlussprüfung wurde die unabhängige Persistenzsynchronisierung ergänzt und die gesamte betroffene Systemsuite erfolgreich erneut ausgeführt. Ein abschließend ergänzter geänderter Replay-Request lief fokussiert; kein unveränderter Gesamtlauf oder App-Build für reine Test-/Kommentar-/Dokumentationsergänzungen wiederholt.

Der erste Xcode-Aufruf scheiterte am bekannten Sandboxzugriff auf den Benutzer-Manifestcache (`/tmp/machosts-retirement-build.log`); der freigegebene Wiederholungslauf bestand. Keine Warnungen aus eigenem Swift-Code; Xcode meldet den mangels Frameworkabhängigkeit ausgelassenen AppIntents-Metadatenschritt. Kein App-Start, keine UI-/Wake-/VM-Tests, keine Systemautorisierung und keine Stromausfallprüfung. Standard-Workspace und Hosts-Datei des Arbeitsrechners einschließlich Rechte/Metadaten wurden weder gelesen noch verändert. Gate 0 und Gate 4 bleiben offen.

## Offene Phase-4-Arbeiten und Grenzen

- Enges produktives Toolrequestprotokoll, sichere privilegierte Requestübergabe und Toolherkunft benötigen weiterhin Gate 0. Es gibt keinen produktiven Autorisierungsadapter und keinen funktionierenden Systemwriter.
- Der interne Transaktionskern und die privaten Dateifixtures ersetzen keinen produktiven root-eigenen Dateiadapter. Vertrauenswürdige Systemverzeichnisse, vollständiger System-Metadatenvertrag, streng begrenztes/eindeutiges Transport-/Journalschema, Retention und die vollständige privilegierte Prozessabbruchmatrix sind offen. Die private Anbindung an den ApplyCoordinator und die oben ausgewiesenen echten Prozessneustarts sind geprüft. Die Fixture-Journale sind nicht als untrusted privilegierter JSON-Eingang freigegeben; aktuell gibt es keine produktive Transportdekodierung. Historische Journale/Backups werden in den begrenzten Tests vollständig erhalten; keine produktive Retention behauptet. App-Snapshot-Abbrüche und unabhängige App-/Worker-Lebenszyklen sind nun ebenfalls an privaten Fixtures geprüft. Die unprivilegierte Dateibeobachtung und ihr App-Zustandsmodell sind mit privaten Fixtures geprüft; die App-Anbindung ist implementiert und gebaut, native UI-/Wake-Abnahme bleibt offen. Verwaiste App-Absichten ohne Systemjournal werden jetzt ausdrücklich diagnostiziert und bleiben blockiert (siehe Ergänzung). Die interne Stilllegung mit Worker-Ausschluss und dauerhaftem Replay-Schutz ist jetzt gemäß ADR 0003 geprüft (siehe Ergänzung). Die produktive Auflösung benötigt weiterhin sichere Autorisierung, Transport und unabhängige Persistenz; fehlende Nachweise dürfen keinen Nicht-Commit vortäuschen. Für die produktive Integration bleibt Gate 0 erforderlich. Die Experimentsuite wurde nicht ungeprüft als Produktcode übernommen.
- Keine Recovery nach realem privilegiertem Toolabbruch, kein Multiuser-Nachweis, keine Cache-Flush-/Resolverintegration und keine native UI-/Wake-Abnahme der jetzt angebundenen Dateisystembeobachtung. Diese Bestandteile, VM-Matrix und vollständiges Gate 4 bleiben offen.
- App und Systemdatei bleiben getrennte Transaktionen. Ein tatsächlicher App-Neustart öffnet den Workspace neu und muss vor neuer Übernahme abgleichen. Ein „applied“ bleibt ein bestätigter historischer Stand; aktuelle externe Abweichung ergibt sich erst aus dem erneuten Lesen. Ein nicht kooperierender Schreiber kann nach einem Readback erneut ändern; es gibt kein atomisches Compare-and-Swap über beliebige Fremdprogramme.
- JSON-Archive und Vorgänger sind lokale App-Recovery. Sie ersetzen keine unabhängige systemseitige Journal-/Receiptdatenbank. Rückkehr zu einem älteren Build unterstützt Schema 2 nicht; kein automatisches Daten-Downgrade.

Die Hosts-Datei des Arbeitsrechners wurde weder gelesen noch verändert; ebenso keine Rechte oder Metadaten. Keine Root-Ausführung, keine Systemautorisierung, keine VM-Tests, keine Veröffentlichung. Der Arbeitsordner hat weiterhin kein Git-Repository; ein Git-Diff/Clean-Checkout-Nachweis ist deshalb nicht verfügbar. Die geänderten Quell- und Testdateien wurden direkt geprüft.
