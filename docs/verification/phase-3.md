# Phase 3 – Workspace-Speicher und lokale Recovery

Stand: 25. Oktober 2026. **Implementiert und lokal verifiziert; Gate 3 für das initiale Schema 1 bestanden.** Phase 2 ist lokal bestanden. Die formalen Clean-Checkout-/CI-Nachweise aus Phase 1 bleiben offen. Gate 0 und echte privilegierte Integration sind weiterhin zurückgestellt.

Aktueller Folgestand: [Phase 4](phase-4.md) erweitert den App-Snapshot auf Schema 2 und ergänzt die gesicherte Migration von Schema 1. Die folgenden Ergebnisse dokumentieren den ursprünglichen Phase-3-Abschluss.

## Implementiert

- `WorkspaceStore` ist ein Actor mit versioniertem `WorkspaceSnapshot`, monotoner Speichergeneration und revisionsgeprüften Entwürfen. Die Profildaten enthalten stabile IDs, Reihenfolge, Ordner und Papierkorb. Löschen/Wiederherstellen erhält den Text; Wiederherstellung aktiviert kein Profil automatisch.
- Dateiarbeit liegt außerhalb des Main Actors. Die explizit übergebene App-Datenablage wird als private, nutzereigene Leaf-Directory erstellt/geprüft; ihr Elternverzeichnis muss bestehen. Die spätere App-Integration wählt den vorgesehenen Application-Support-Pfad. Tests verwenden ausschließlich UUID-Verzeichnisse im temporären Bereich.
- Deskriptorrelative Zugriffe, `O_NOFOLLOW`, reguläre Dateien, Eigentümer, private Rechte, Linkanzahl und streamende Größenprüfung begrenzen die Dateigrenze. Root-Ausführung wird abgewiesen. Ein dauerhaft gehaltener `flock` verhindert einen zweiten kooperierenden Writer; die Lockdatei wird niemals entlinkt.
- Vor Veröffentlichung wird der letzte bestätigte Snapshot als `workspace.previous.json` gesichert. Neue Bytes gehen in eine exklusive `0600`-Tempdatei desselben Verzeichnisses, werden per `fsync` gesichert und nach erneuter Digestprüfung atomar umbenannt. Verzeichnisflush und Readback folgen. Fehler vor Rename bestätigen keinen neuen Stand; Fehler danach markieren einen unklaren Ausgang und sperren weitere Saves bis zum erneuten Öffnen.
- Beschädigtes, abgeschnittenes, unsicheres, übergroßes oder unbekanntes Schema wird nicht durch einen leeren Workspace ersetzt. Der gültige Vorgänger ist nur ein Recoverykandidat. Auch eine fehlende Hauptdatei neben einem defekten Backup führt nicht zum stillen Neustart mit leeren Daten.
- `recoverPrevious` benötigt eine ausdrückliche Auswahl und den aktuellen Digest. Der beschädigte Originalsnapshot wird zuvor unter einem eindeutigen `workspace.recovery-UUID.json` archiviert. Unbekannte Schemata werden nicht zurückgestuft. Schema 1 ist das erste Produktformat; es existiert kein unterstütztes Vorgängerformat und folglich noch keine Migration. Schema 0 und zukünftige Versionen bleiben schreibgeschützt; spätere Migrationen brauchen eigene Fixtures und Backups.
- Der bestätigte angewendete Workspace ist vom Entwurf getrennt und an Plan-/Workspace-Digest sowie verifizierten Readback im Receipt gebunden. Ein Cache-Flushfehler bleibt separat und verhindert nicht die Speicherung eines bestätigten File-Ergebnisses. Das Modell stellt selbst keinen privilegierten Schreibnachweis aus. Ein erneuter Abgleich mit tatsächlichem Systemzustand und Toolreceipt gehört zu Phase 4.
- `WorkspaceAutosave` bündelt schnelle Änderungen, behält fehlgeschlagene Entwürfe und den Fehler im Zustand und bietet `flush` für den Abschluss. Gleichzeitige Flush-Aufrufe teilen den laufenden Save. Ersetzte Debounce-Timer brechen keinen begonnenen Commit ab. Unabhängige Store-Änderungen werden über die Generation erkannt; die spätere App muss Store und Autosave gemeinsam koordinieren.

## Tatsächlich verifiziert

Apple Silicon, Xcode 27.1 / Swift 6.4, macOS-SDK 27.0; Swift-6-Concurrency-Prüfung. Befehle und Cachepfade entsprechend [ENTWICKLUNG.md](../ENTWICKLUNG.md).

| Prüfung | Ergebnis |
| --- | --- |
| Gesamtes Swift-Package | bestanden: 15 Services-, 12 Core- und 1 Writer-Sperrtestfunktion; parametrisierte Fälle zusätzlich; `/tmp/machosts-phase3-swift-test.log` |
| Neustart/Roundtrip | Entwurf, angewendeter Snapshot, Receipt und Separatornachweis bleiben getrennt erhalten; Dateimodus `0600` geprüft |
| Fehler-/Recoveryfälle | abgeschnittenes JSON, Schema 0/99, explizite Recovery mit Originalarchiv, falscher Digest, fehlende Hauptdatei mit defektem Backup |
| Schreibfehler/Unterbrechung | injiziertes ENOSPC vor Write/vor Rename/nach Rename, EACCES vor Rename; erneutes Öffnen rekonstruiert alten bzw. neuen tatsächlich veröffentlichten Snapshot |
| Nebenläufigkeit | zweite Storeinstanz abgewiesen, parallele erwartete Generationen erlauben genau einen Save, externe Änderung wird erhalten und blockiert weitere Saves |
| Dateigrenze | Symlink, Hardlink, unsichere Verzeichnisrechte und übergroße Snapshotdatei abgewiesen; private Zieldatei unverändert |
| Autosave | 25 Entwürfe zu einem Save gebündelt, paralleler Flush, echter verzögerter Timer und fehlerhaftes Save mit erhaltenem Dirty-Zustand |
| Strikte rekursive Formatprüfung | bestanden; `/tmp/machosts-phase3-format.log` |
| Inkrementeller Xcode-Release-Build | bestanden; `/tmp/machosts-phase3-build.log`; Cachezugriff außerhalb der Coding-Sandbox erforderlich |

Keine Swift-Compilerwarnungen im eigenen Code im finalen Lauf. SwiftPM weist in der Sandbox auf nicht verfügbare optionale Benutzer-Caches hin. Xcode meldet die erwartete ausgelassene AppIntents-Metadatenextraktion ohne entsprechende Framework-Abhängigkeit. Im ersten Speicherbuild wurden `timespec`-Felder statt eines nicht verfügbaren Equatable-Vergleichs verwendet; der abschließende Lauf bestand.

## Grenzen und Fortsetzung

Die Unterbrechungspunkte sind deterministische Fehlerinjektionen am tatsächlichen privaten Dateipfad, keine behaupteten Power-Loss-/Hardwaretests. Unvollständige unbestätigte Tempdateien nach einem echten Prozessende werden nicht automatisch angewendet; vorhandene bestätigte Snapshots und Vorgänger bleiben die Recoverybasis. Ein nicht kooperierender Schreiber desselben Nutzers kann zwischen letzter Prüfung und Rename eingreifen oder die private Directory austauschen; ein atomarer systemweiter Compare-and-Swap wird nicht behauptet.

Keine systemweite Recovery, UI-Recoveryauswahl, App-Autosave-Anbindung oder neue Profiloberfläche in diesem Abschluss. Unbekannte/neue Schemata bleiben für einen späteren kompatiblen Build erhalten; kein spekulativer Import oder Daten-Downgrade. Backups halten einen Vorgänger; ausdrücklich erzeugte Recoveryarchive werden nicht automatisch gelöscht. Aufbewahrung/Export und die Oberfläche folgen in späteren Phasen.

Der unverfügbare Systemwriter ist unverändert und durch den Vertragstest geschützt. Keine Hosts-Datei des Arbeitsrechners gelesen oder verändert, keine Autorisierung, keine Rootprozesse, keine Netzwerkkommunikation und keine Veröffentlichung. Nächster fachlicher Block ist Phase 4: Apply-Koordination und Recovery mit privaten Fixtures; produktive Autorisierung und der Integrationsabschluss benötigen weiterhin Gate 0 und die vertagten VM-Nachweise.
