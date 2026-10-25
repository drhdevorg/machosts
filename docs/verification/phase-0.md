# Phase 0 – lokale Vorbereitung

Datum: 25. Oktober 2026. **Status: lokale Vorbereitung abgeschlossen; Gate 0 nicht bestanden / Nachweise ausstehend.** Der Nutzer hat ausdrücklich entschieden, VM-Tests vorerst offenzulassen. Gate 0 ist inzwischen gemäß [ADR 0002](../decisions/0002-deferred-gate-0.md) zurückgestellt; unabhängige Produktentwicklung ab Phase 1 ist erlaubt. Die folgenden Nachweise und älteren Fortsetzungsberichte beschreiben ihren jeweiligen damaligen Stand.

## Implementierte Artefakte

Unter [Experiments/AuthorizationProbe](../../Experiments/AuthorizationProbe/README.md) liegen ein eigenständiges Swift-Package, eine native SwiftUI-Demo, ein kurzlebiges unprivilegiertes Demo-Tool, ein lokaler Packager und Swift-Testing-Tests. Keine externen Package-Abhängigkeiten, kein Developer-Team, keine Kennwortverwaltung und kein frei wählbarer Systemschreibpfad.

Der Teststore erzeugt seine eigene private Wegwerfdatei. Er prüft Requestform, erwarteten Digest, mehrdeutige Blockmarker und bestehende Symlink-/Hardlinkziele; er erzeugt Backup, Journal und Receipt. Simulierte Fehler vor/nach Commit werden rekonstruiert. Ein fremder neuer Stand verhindert automatisches Überschreiben. Das ist ein begrenztes Modell des späteren Ablaufs, kein für Root geeigneter Dateisystemcode.

Die App kann denselben lokalen Apply-/Readback-/Restore-Ablauf ausführen. Ein separat freischaltbarer VM-Button enthält ausschließlich den festen OS-Autorisierungsaufruf für Apples `/usr/bin/id -u`. Er wurde hier **nicht betätigt**. Die eigene GUI und das Demo-Tool lehnen Root-Ausführung im Code ab; diese Root-Ablehnung wurde nicht durch einen tatsächlichen Root-Start getestet.

## Umgebung

- Apple Silicon / arm64, Host macOS 27.0.1, Xcode 27.1 (27A9275), Swift 6.4, SDK 27.0.
- Package-Deployment Target 27.0, Swift-6-Sprachmodus.
- UTM unter `/Applications/UTM.app` vorhanden. `utmctl list` beendete sich ohne Ausgabe mit Exit 134. Keine `.utm`-VM in den beiden geprüften üblichen Verzeichnissen gefunden; dies ist keine vollständige Inventarisierung aller Nutzerlaufwerke.
- Ausführung unter bestehender Dateisystem-/Prozess-Sandbox. Module-/Package-Caches auf beschreibbare `/tmp/machosts-phase0-*`-Pfade gelegt, ohne `$HOME` oder `$CODEX_HOME` umzusetzen.

## Tatsächlich bestandene Prüfungen

| Prüfung | Ergebnis |
| --- | --- |
| Debug-Build aller Targets und Swift-Testing-Suite | bestanden; 12 Testfunktionen, darunter parametrisierte Fälle |
| Unbekannte Requestfelder / Operationen, Digestformat, Übergröße | abgewiesen wie erwartet |
| Fremdbytes mit CRLF, UTF-8-Kommentaren, fehlendem letzten LF | Verhalten mit Fixtures belegt |
| Defekte/doppelte/umgekehrte Marker | Write-Komposition abgewiesen |
| Normaler Apply, Readback und Vollbackup-Restore an privater Fixture | Originalbytes exakt wiederhergestellt |
| Veralteter Request nach Apply | abgewiesen; aktueller Inhalt erhalten |
| No-op bei nicht vorhandenem eigenen Block | ohne Backup-/Journalpfad erfolgreich |
| Fehlerinjektion vor Backup, nach Backup, nach Journal, nach Ersetzen, nach Receipt | erwarteter Zustand rekonstruiert |
| Externe Änderung nach simuliertem Commit-Abbruch | bleibt unverändert; weiterer Apply gesperrt |
| Symlink und Hardlink am Testziel | Lesen abgewiesen; referenzierte Datei unverändert |
| Release-Build mit lokalem nativen SwiftPM-Builder | bestanden |
| Demo-CLI direkt und aus signiertem Bundle mit `--demo` | bestanden, Exit 0 |
| CLI mit `--target /private/etc/hosts` | abgewiesen, erwarteter Exit 64; Ziel wurde nicht geöffnet |
| `swift-format lint --strict` | bestanden |
| App-/ZIP-Paketierung ohne Account-/Teamkonfiguration | bestanden |
| `codesign --verify --deep --strict --verbose=2` | Bundle und eingebettete Binary validiert |
| `codesign --display --verbose=4` | arm64, `Signature=adhoc`, Flags `adhoc,runtime`, `TeamIdentifier=not set` |
| `otool -L` auf eingebettetem Demo-Tool | nur `/usr/lib`- und `/System/Library`-Abhängigkeiten im geprüften Artefakt |

Die zwölf Testfunktionen prüfen das Modell, nicht den späteren privilegierten Writer. Stale-Digest-Abweisung ist kein vollständiger Replay-Schutz nach Rückkehr auf einen identischen Dateistand. Fehlerinjektion ist kein realer Prozessabsturz oder Stromausfalltest.

### Wichtige Befehle

Alle Befehle aus dem Repository-Root. Anleitung zum Wiederholen: [Experiment-README](../../Experiments/AuthorizationProbe/README.md).

```sh
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules swift test --package-path Experiments/AuthorizationProbe --scratch-path /tmp/machosts-phase0-build --cache-path /tmp/machosts-phase0-cache --disable-sandbox
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules swift build --build-system native -c release --package-path Experiments/AuthorizationProbe --cache-path /tmp/machosts-phase0-cache --disable-sandbox
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules Experiments/AuthorizationProbe/.build/arm64-apple-macosx/release/PackageProbe
Experiments/AuthorizationProbe/Output/MacHostsAuthorizationProbe.app/Contents/MacOS/MacHostsProbeTool --demo
codesign --verify --deep --strict --verbose=2 Experiments/AuthorizationProbe/Output/MacHostsAuthorizationProbe.app
xcrun swift-format lint --strict --recursive Experiments/AuthorizationProbe/Sources Experiments/AuthorizationProbe/Tests Experiments/AuthorizationProbe/Package.swift
```

Letzter Testlauf: `Test run with 12 tests in 0 suites passed`; Toolausgabe: `PASS: isolated fixture apply, readback and exact restore; no system file accessed.`

## Lokales Download-Artefakt

- App: `Experiments/AuthorizationProbe/Output/MacHostsAuthorizationProbe.app`
- ZIP: `Experiments/AuthorizationProbe/Output/MacHostsAuthorizationProbe.zip`
- SHA-256 des erzeugten ZIP: `8bf05473bd9229da1bf952021d32198e2e24ac02537b0bbc0f68a8a5b2fb0c9e`
- Gemessene belegte Größe per `du`: App 500 KiB, ZIP 132 KiB; dies ist ein Minimalexperiment und keine Prognose für die Produkt-App.

`Output` und Buildverzeichnisse sind generiert und in `.gitignore` ausgeschlossen. Kein Upload, keine Veröffentlichung. Bei Neuverpackung ändert sich der ZIP-Digest; der Packager überschreibt bestehende App-Artefakte absichtlich nicht.

## Aufgedeckte Probleme und Grenzen

1. Ein Test mit CRLF schlug zuerst fehl: Swift-String-Splitting auf `\n` erfasste CRLF nicht wie beabsichtigt. Marker-Erkennung arbeitet nun auf Bytes. Danach bestanden sämtliche Tests.
2. Der erste Manifest-Build wollte einen nicht beschreibbaren globalen Clang-Cache verwenden; lokale Cachepfade beheben das.
3. Release mit dem neuen Standard-SwiftPM-Builder scheiterte beim dSYM-Schritt mit `Operation not permitted`. Der native Builder bestand. Er ist deprecated und nur lokale Prototyp-Ausweichlösung, kein dauerhafter Produktstandard. User-Cache-Warnungen und einzelne `sandbox-exec`-Diagnosen im erfolgreichen nativen Build sind protokollierte Umgebungsgrenzen.
4. Der erste Packageraufruf scheiterte an der zusätzlichen SwiftPM-Sandbox der internen Binärpfadabfrage. Die Abfrage verwendet nun ebenso `--disable-sandbox`; anschließend wurde das Bundle erfolgreich erzeugt und geprüft. Dies schaltet weder SIP noch Gatekeeper ab.
5. Computer Use wurde für die neue App nicht freigegeben. Daher kein bestätigter GUI-Start, kein Klicktest und keine visuelle QA; es wird nicht auf andere UI-Steuerungswege ausgewichen.
6. Der Fixture-Store verwendet Foundation-Atomics und Vorab-`lstat`; seine TOCTOU-, fsync-, Metadaten- und Restore-/Mehrprozessgrenzen sind im Experiment-README ausdrücklich beschrieben. JSON-Duplikatschlüssel werden inzwischen am Wire-Eingang abgewiesen, siehe Ergänzung unten. Keine Freigabe für Root oder Produktcode.

## Fortsetzung: eindeutiger Request-Eingang

Am 25. Oktober 2026 wurde ausschließlich der lokale Phase-0-Prototyp weiterbearbeitet. `ProbeRequest.decode` prüft das maximal 16 KiB große, flache JSON-Objekt vor dem typisierten Decoding. Doppelte Schlüssel werden anhand ihrer decodierten Zeichenketten abgewiesen, einschließlich Unicode-Escapes und unabhängig von der Reihenfolge. Verschachtelte Werte, ungültige String-Escapes, zusätzliche Daten nach dem Objekt und abgeschnittene Requests werden abgewiesen. Feldreihenfolge und JSON-Leerzeichen bleiben frei. Das numerische Versionsfeld erlaubt nur ganzzahlige JSON-Schreibweise.

Neue Verhaltenstests prüfen identische und widersprüchliche Duplikate aller vier Felder vor und nach dem ursprünglichen Feld, einen escaped Duplikatschlüssel, gültige umsortierte/escaped Schlüssel, fehlerhafte JSON-Hüllen sowie jede Abschneidestelle eines gültigen Requests. Die Prüfung ist nur für `ProbeRequest.decode` belegt; direktes Codable-Decoding kann doppelte Schlüssel nicht erkennen. Sichere Übergabe, Replay-Schutz und privilegierte Requestintegrität bleiben offen.

Erneut ausgeführt mit den oben dokumentierten Befehlen: Debug-Build aller Targets und Swift-Testing-Suite bestanden (`Test run with 16 tests in 0 suites passed`); `swift-format lint --strict --recursive` bestanden, Exit 0. SwiftPM meldete weiterhin die nicht beschreibbaren nutzerweiten Cacheverzeichnisse; die lokalen `/tmp`-Caches wurden verwendet. Release-/Signatur-/GUI- und VM-Prüfungen wurden bei dieser Ergänzung nicht wiederholt.

Die vorhandenen App-/ZIP-Artefakte unter `Output` wurden bei dieser Fortsetzung nicht neu gebaut; ihr oben dokumentierter Digest gehört zum früheren Build und enthält diese Ergänzung nicht. Kein Systemwrite, kein Autorisierungsaufruf und kein Beginn von Phase 1. Der Arbeitsordner enthält kein Git-Repository; deshalb war keine Git-Diffprüfung möglich. Die geänderten Quelldateien wurden direkt geprüft.

## Noch nicht ausgeführt / nicht nachgewiesen

- Sichere Übergabe und geschützter Start einer eigenen Swift-Binary als Root, inklusive Library- und Updatepfad.
- Tatsächliche Systemautorisierung inklusive Abbruch/Caching/Timeout auf macOS 27.
- Prozess-Kill/Neustart und Stromausfall-/Durability-Verhalten.
- Echte Hosts-Transaktion, Metadaten, DNS-Cache-Operation und bytegenaue VM-Systemwiederherstellung.
- Erststart eines quarantänisierten Download-Artefakts, Installation/Update und mehrere Benutzer in einer frischen VM.
- Visuelle/UI-Abnahme der SwiftUI-Oberfläche.

Die Hosts-Datei des Arbeitsrechners wurde durch diesen Prototyp weder geöffnet noch geschrieben. Es wurden keine Root-Dienste installiert, keine Systemautorisierung angefordert und keine Schutzfunktionen abgeschaltet.

## Fortsetzung: begrenztes Lesen und Apply-Größenlimit

Am 25. Oktober 2026 wurde der unprivilegierte Fixture-Store weiter ergänzt. Bisher lud `Data(contentsOf:)` die ganze Datei, bevor das 1-MiB-Limit geprüft wurde. Der Store liest nun in Chunks von höchstens 64 KiB und insgesamt höchstens 1 MiB plus einem Prüfbyte. Das gilt für Fixture, Backup, Journal und Receipt. Der Handle wird auch nach Lese-/Limitfehlern geschlossen; ein Schließfehler lässt die Operation ebenfalls fehlschlagen. Die bestehende Lücke zwischen `lstat` und Öffnen bleibt ausdrücklich offen.

Zusätzlich stoppt Apply einen Zielinhalt über 1 MiB vor Backup und Journal. Damit erzeugt ein gültiger Ausgangsstand am Limit keinen übergroßen Write mit anschließend fehlschlagendem Readback. Neue Tests prüfen leere Dateien, Chunkgrenzen, exakt 1 MiB, ein Byte darüber, doppelte Größe und das Überschreiten durch Blockanhängen. Abgewiesenes Apply erhält die Fixture und erzeugt keine Transaktionsartefakte. Ein übergroßes Recovery-Backup lässt Ziel und offenes Journal unverändert; weitere Applies bleiben gesperrt.

Verifikation mit den oben dokumentierten Befehlen: Debug-Build aller Targets und Swift-Testing-Suite bestanden (`Test run with 20 tests in 0 suites passed`); rekursive strikte Formatprüfung bestanden, Exit 0. Die unveränderten SwiftPM-Warnungen über nicht beschreibbare nutzerweite Caches bleiben; verwendet wurden die lokalen `/tmp`-Caches. Die geänderten Quellen und Tests wurden direkt geprüft; weiterhin kein Git-Repository im Arbeitsordner.

Die vorhandenen Output-App-/ZIP-Artefakte wurden nicht neu erstellt. Keine echte Systemdatei geöffnet oder verändert, keine Systemautorisierung aufgerufen. Gate 0 bleibt offen und Phase 1 unbegonnen; VM-, Release-/Signatur- und UI-Prüfungen wurden nicht ausgeführt.

## Fortsetzung: Prüfung des tatsächlich geöffneten Leseobjekts

Am 25. Oktober 2026 wurde ausschließlich das Lesen im unprivilegierten Fixture-Store weiterentwickelt. Statt `lstat` mit anschließendem erneutem Öffnen verwendet es nun `open` mit `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` und prüft per `fstat` den tatsächlich geöffneten Dateideskriptor auf regulären Dateityp, genau einen Hardlink und den eigenen Nutzer als Eigentümer. Der so geprüfte Deskriptor wird für das begrenzte Lesen verwendet und auch nach Validierungs- oder Lesefehlern geschlossen. Ein Schließfehler wird nicht verschluckt. Diese Ergänzung ersetzt die oben dokumentierte Lese-Lücke; der pfadbasierte Schreibweg bleibt unverändert.

Zwei neue parametrisierte Testfunktionen prüfen Verzeichnis, FIFO und verwaisten Symlink am Fixturepfad sowie Symlinks und Hardlinks an Backup, Journal und Receipt. Recovery/Restore verweigert diese Artefakte, lässt Zielbytes, referenzierte Bytes und vorhandene Verzeichniseinträge unverändert; offene Journale blockieren weiter Apply. Die bestehenden Größen-, Link-, Apply- und Recoverytests bestehen ebenfalls.

Verifikation mit den oben dokumentierten Befehlen: Debug-Build aller Targets und Swift-Testing-Suite bestanden (`Test run with 22 tests in 0 suites passed`); `xcrun swift-format lint --strict --recursive` bestanden, Exit 0. SwiftPM meldete die weiterhin nicht beschreibbaren nutzerweiten Cacheverzeichnisse; die lokalen `/tmp`-Caches wurden verwendet. Quellen, Tests und Dokumentationsänderungen wurden direkt geprüft; der Arbeitsordner ist weiterhin kein Git-Repository.

Dieser Testlauf beweist keinen Schutz bei ausgetauschten Elternverzeichnissen oder konkurrierenden Änderungen am bereits geöffneten Inode. Kein deterministischer Race-/Mehrprozesstest, keine fsync-/Durabilityprüfung und keine Freigabe für Root. Die Lücke zwischen Vorabprüfung und Ersetzen beim Schreiben bleibt offen. Neue Release-/Signatur-, GUI- oder VM-Prüfungen wurden nicht ausgeführt; vorhandene Output-App-/ZIP-Artefakte wurden nicht aktualisiert. Keine Systemhosts-Datei geöffnet oder geändert, keine Systemautorisierung angefordert. Gate 0 bleibt offen, Phase 1 unbegonnen.

## Fortsetzung: journalisierte Fixture-Wiederherstellung

Am 25. Oktober 2026 wurde ausschließlich der lokale Phase-0-Prototyp ergänzt. `restoreOriginal` verwendete zuvor direktes Ersetzen und Readback ohne Transaktionsjournal. Apply und Restore verwenden nun eine gemeinsame Commitfunktion: Vorher-Backup, Journal, Revisionsprüfung, Ersetzen, Readback und Receipt. Ein internes Enum im Journal wählt feste Artefaktnamen für Apply bzw. Restore; kein Request kann einen Pfad bestimmen. Restore sichert den unmittelbar vorherigen Stand in `restore-before.bin` und bestätigt ihn über `restore-receipt.json`. Das ursprüngliche `original.bin` und `receipt.json` bleiben dabei byteidentisch erhalten. Recovery prüft das zur Operation gehörende Backup und rekonstruiert vor/nach Commit ohne automatisches Zurückschreiben.

Vier neue Testfunktionen, darunter eine mit fünf Unterbrechungspunkten, prüfen Fehler vor Backup, nach Backup, nach Journal, nach Ersetzen und nach Receipt. Offenes Restore-Journal sperrt weitere Applies und Restores. Nach Recovery ist ein erneuter Restore möglich; ein bereits restaurierter Stand ist ein No-op ohne neue Artefaktwrites. Zusätzlich geprüft: veralteter Digest, unveränderte ursprüngliche Apply-Artefakte, eigenes Restore-Receipt mit neuer Transaktions-ID, beschädigtes Restore-Backup sowie externe Änderungen nach unterbrochenem Restore. Bei beschädigtem Backup oder fremdem Iststand bleiben Ziel und Journal erhalten.

Verifikation mit den oben dokumentierten Debug-Test- und Formatbefehlen: Debug-Build aller Targets bestanden, `Test run with 26 tests in 0 suites passed`; `xcrun swift-format lint --strict --recursive` bestanden, Exit 0. SwiftPM meldete unverändert nicht beschreibbare nutzerweite Cacheverzeichnisse; die lokalen `/tmp`-Caches wurden verwendet. Geänderte Quellen und Tests wurden direkt geprüft; der Arbeitsordner enthält weiterhin kein Git-Repository.

Die Tests simulieren Unterbrechungen in derselben Sitzung. Keine Prozess-Kill-/Neustart-, Mehrprozess-, fsync- oder Stromausfallprüfung. Die bisherigen Grenzen des pfadbasierten Writers bleiben bestehen; keine Root-Freigabe. Das interne Journalformat wurde geändert, ohne Migration alter Experimentjournale; bestehende Sitzungsverzeichnisse werden vom Prototyp ohnehin nicht wieder geöffnet. Vorhandene Output-App-/ZIP-Artefakte wurden nicht aktualisiert; keine erneute Release-/Signatur-, GUI- oder VM-Prüfung. Keine Systemhosts-Datei geöffnet oder verändert, keine Systemautorisierung angefordert. Gate 0 bleibt offen, Phase 1 unbegonnen.

## Fortsetzung: unsichere Transaktionsartefakte vor Writes abweisen

Am 25. Oktober 2026 wurde der lokale Fixture-Store weiter korrigiert. Die bisherige `fileExists`-Prüfung folgte Journal-Symlinks und übersah dabei einen verwaisten Symlink. Apply konnte dadurch bereits ein Backup ersetzen, bevor das Schreiben des Journals scheiterte; Recovery meldete fälschlich eine saubere Sitzung. Die Anwesenheitsprüfung verwendet jetzt `lstat`, behandelt jeden vorhandenen Journaleintrag als offen und reicht andere Lookupfehler als Fehler weiter. Apply und Restore bleiben gesperrt; Recovery prüft das vorhandene Objekt über den bestehenden deskriptorgeprüften Leser und weist unsichere Dateitypen ab.

Zusätzlich prüft die gemeinsame Commitfunktion vor dem ersten Backupwrite die festen Backup- und Receiptziele auf regulären Dateityp, eigenen Eigentümer und genau einen Hardlink, sofern diese bereits existieren. Zuvor wurde ein unsicheres Receiptziel erst nach Ersetzen der Fixture erkannt. Die Vorabprüfung betrifft tatsächliche Änderungen; No-op bleibt ohne Transaktionswrites.

Zwei neue parametrisierte Testfunktionen prüfen insgesamt 25 Fälle: fünf unsichere Journaltypen sowie fünf Dateitypen an jeweils vier Apply-/Restore-Artefaktpfaden. Geprüft wurden verwaiste Symlinks, Symlinks, Hardlinks, Verzeichnisse und FIFOs. Bei Abweisung bleiben Fixture, übrige Backup-/Receiptbytes, referenzierte fremde Bytes und Verzeichniseinträge erhalten. Ein defekter Journaleintrag blockiert Apply und Restore und wird bei Recovery nicht als sauber akzeptiert.

Verifikation mit den oben dokumentierten Befehlen: Debug-Build aller Targets und Swift-Testing-Suite bestanden (`Test run with 28 tests in 0 suites passed`); rekursive strikte Formatprüfung bestanden, Exit 0. SwiftPM meldete weiterhin die nicht beschreibbaren nutzerweiten Cacheverzeichnisse; verwendet wurden die lokalen `/tmp`-Caches. Geänderte Quellen und Tests wurden direkt geprüft; weiterhin kein Git-Repository im Arbeitsordner.

Die Vorabprüfung schützt vor bereits vorhandenen unsicheren Einträgen, schließt aber keine konkurrierenden Pfad-/Inodeänderungen zwischen Prüfung und Ersetzen aus. Keine Root-Freigabe, keine Mehrprozess-, Prozess-Kill- oder fsync-Prüfung. Release-/Signatur-, GUI- und VM-Prüfungen wurden nicht ausgeführt; bestehende Output-App-/ZIP-Artefakte wurden nicht neu erstellt. Keine Systemhosts-Datei geöffnet oder verändert, keine Systemautorisierung angefordert. Gate 0 bleibt offen, Phase 1 unbegonnen.

## Fortsetzung: gespeicherte Transaktionsdaten auf Konsistenz prüfen

Am 25. Oktober 2026 wurde die lokale Recovery ergänzt. Bisher genügte ein decodierbares Journal mit passendem Backup-Digest. Beispielsweise konnte ein beschädigtes Journal mit identischem Vorher-/Nachher-Digest einen nicht ausgeführten Write als committed einstufen und anschließend gelöscht werden. Recovery und Restore prüfen gespeicherte Receipts jetzt vor jeder weiteren Änderung: beide Digests müssen 64 kleingeschriebene hexadezimale Zeichen enthalten, unterschiedlich sein und `unchanged` muss `false` sein. No-op-Ergebnisse werden weiterhin nur zurückgegeben und erzeugen keine gespeicherte Transaktion. Fehler beim JSON-Decoding von Journal oder Apply-Receipt werden als `recoveryRequired` gemeldet; Dateityp-, I/O- und Größenfehler bleiben separat erhalten.

Zwei neue parametrisierte Testfunktionen prüfen 18 Fälle: ungültiger Vorher-Digest, ungültiger Nachher-Digest, gleiche Digests, widersprüchliches `unchanged`, abgeschnittenes JSON und fehlender Digest; jeweils an Apply-/Restore-Journalen sowie am Apply-Receipt vor Restore. Nach abgewiesener Recovery bleiben alle Artefaktnamen und Bytes einschließlich Journal erhalten, weitere Applies und Restores bleiben gesperrt. Ein beschädigtes Apply-Receipt verhindert Restore ohne neue Transaktionsartefakte oder veränderte Bytes. Die bestehenden Unterbrechungs-, No-op- und Restoretests bestehen weiterhin.

Verifikation mit den oben dokumentierten Debug-Test- und Formatbefehlen: Debug-Build aller Targets bestanden; `Test run with 30 tests in 0 suites passed`; rekursive strikte Formatprüfung bestanden, Exit 0. SwiftPM meldete weiterhin nicht beschreibbare nutzerweite Cacheverzeichnisse; die lokalen `/tmp`-Caches wurden verwendet. Quellen, Tests und Dokumentation wurden direkt geprüft; kein Git-Repository im Arbeitsordner.

Diese Prüfung erkennt die beschriebenen Format-/Konsistenzfehler, beweist aber keine Authentizität gespeicherter Daten und keine sichere Requestübergabe. Zusätzliche oder doppelte JSON-Schlüssel in lokalen Journalen/Receipts werden damit nicht gesondert abgewehrt. Die bisherigen Schreib-/Nebenläufigkeits- und Durabilitygrenzen bleiben offen. Keine erneute Release-/Signatur-, GUI- oder VM-Prüfung; bestehende Output-App-/ZIP-Artefakte wurden nicht aktualisiert. Keine Systemhosts-Datei geöffnet oder verändert, keine Systemautorisierung angefordert. Gate 0 bleibt offen, Phase 1 unbegonnen.

## Fortsetzung: eindeutige JSON-Schemata für Recovery-Daten

Am 25. Oktober 2026 wurde ausschließlich der lokale Phase-0-Prototyp ergänzt. Vor dem Codable-Decoding prüft `TransactionJSON` nun die festen Journal-/Receipt-Schemata. Doppelte Schlüssel werden anhand decodierter Zeichenketten erkannt, einschließlich Unicode-Escapes. Zusätzliche oder fehlende Felder, falsche Werttypen, zusätzliche Daten nach dem Objekt und über die feste Journal-/Receiptstruktur hinausgehende Verschachtelung führen zu `recoveryRequired`. Das bestehende begrenzte, deskriptorgeprüfte Lesen findet davor statt. Die Prüfung erfolgt vor Recovery- oder Restore-Writes; die bisherigen Digest-/Konsistenzprüfungen bleiben erhalten. Das ersetzt die im vorherigen Abschnitt beschriebene Grenze für zusätzliche und doppelte Schlüssel.

Die erweiterten Integrationstests prüfen Apply- und Restore-Journale sowie das Apply-Receipt auf zusätzliche Felder, doppelte Felder einschließlich escaped Schlüsseln, verschachtelte Werte und nachgestellte JSON-Daten. Doppelte `kind`-/`receipt`-Felder werden zusätzlich am äußeren Journal geprüft. Nach Abweisung bleiben alle Artefaktnamen und Bytes erhalten; ein offenes Journal sperrt weitere Transaktionen. Zwei neue parametrisierte Testfunktionen prüfen jede Abschneidestelle gültiger Journal-/Receiptbytes sowie erfolgreiches Recovery/Restore mit escaped Schlüsseln und JSON-Leerzeichen. Insgesamt 32 Testfunktionen, darunter parametrisierte Fälle.

Verifikation mit den oben dokumentierten Debug-Test- und Formatbefehlen: Debug-Build aller Targets bestanden; `Test run with 32 tests in 0 suites passed`; `xcrun swift-format lint --strict --recursive` bestanden, Exit 0. Testprotokoll lokal unter `/tmp/machosts-phase0-latest-test.log`. SwiftPM meldete weiterhin nicht beschreibbare nutzerweite Caches; verwendet wurden die lokalen `/tmp`-Caches. Geänderte Quellen und Tests wurden direkt geprüft; im Arbeitsordner ist weiterhin kein Git-Repository vorhanden.

Die Schemaprüfung beweist keine Authentizität oder unveränderliche Speicherung. Pfad-/Schreibraces, Mehrprozessschutz und Durability bleiben offen. Keine erneute Release-/Signatur-, GUI- oder VM-Prüfung; vorhandene Output-App-/ZIP-Artefakte wurden nicht aktualisiert. Keine Systemhosts-Datei geöffnet oder verändert, keine Systemautorisierung angefordert. Gate 0 bleibt offen, Phase 1 unbegonnen.

## Fortsetzung: fremdbeschreibbare Dateien abweisen

Am 25. Oktober 2026 wurde ausschließlich der unprivilegierte Phase-0-Fixture-Store ergänzt. Die bisherige Prüfung auf eigenen Eigentümer schloss POSIX-Schreibrechte anderer Nutzer nicht aus. Der deskriptorgeprüfte Leser und die pfadbasierte Schreibvorabprüfung weisen jetzt Dateien mit Gruppen- oder Fremdschreibrechten (`mode & 0022 != 0`) als `unsafeFile` ab. Unsichere vorhandene Artefakte werden nicht durch nachträgliches chmod akzeptiert. Die Regeln gelten für Fixture, Backup, Journal und Receipt einschließlich der Restore-Artefakte.

Vier neue parametrisierte Testfunktionen prüfen 18 Fälle: unsichere Fixture-Modi 0620, 0602 und 0666; Gruppen-/Fremdschreibrechte an allen vier Apply-/Restore-Ausgabearten sowie an Apply-Journal und -Backup während Recovery. Bei Abweisung bleiben sämtliche Artefaktnamen und Bytes unverändert; offene Journale sperren weitere Transaktionen. Die Eingangsprüfung von Backup und Receipt vor Restore ist ebenfalls geprüft. Modi 0400, 0600 und 0644 bleiben lesbar.

Verifikation mit den oben dokumentierten Befehlen: Debug-Build aller Targets und Swift-Testing-Suite bestanden (`Test run with 36 tests in 0 suites passed`); rekursive strikte Formatprüfung bestanden, Exit 0. Testprotokoll: `/tmp/machosts-phase0-latest-test.log`. SwiftPM meldet weiterhin nicht beschreibbare nutzerweite Caches; verwendet wurden die lokalen `/tmp`-Caches. Quellen und Tests direkt geprüft; weiterhin kein Git-Repository im Arbeitsordner.

Die Prüfung betrifft POSIX-Modusbits, keine ACLs. Sie schließt weder spätere Rechteänderungen noch die bekannten Pfad-/Schreibraces, Mehrprozess- und Durabilitylücken. Keine Root-Freigabe. Release-/Signatur-, GUI- und VM-Prüfungen nicht wiederholt; Output-Artefakte nicht aktualisiert. Keine Systemhosts-Datei geöffnet oder verändert, keine Systemautorisierung angefordert. Gate 0 bleibt offen, Phase 1 unbegonnen.

## Nächster Schritt

Nach der vom Nutzer gewünschten Vertagung der VM-Tests endet dieser Arbeitsabschnitt bei der lokalen Vorbereitung. Für Gate 0 den Kandidaten aus [ADR 0001](../decisions/0001-privileged-write.md) weiter konkretisieren und die fehlenden Tests in einer bestätigten Wegwerf-VM nachholen. Unabhängig davon mit Phase 1 gemäß ADR 0002 fortfahren; der produktive privilegierte Writer bleibt bis zum Nachweis gesperrt. Die Frage nach der Produktrichtung ist weiterhin entschieden; offen sind technische Nachweise, keine erneute Freigabe der bereits vereinbarten Produktziele.
