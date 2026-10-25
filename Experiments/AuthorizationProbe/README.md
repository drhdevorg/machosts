# Authorization Probe – Phase 0

Unprivilegierter Machbarkeitsprototyp, **keine fertige MacHosts-App** und kein freigegebener privilegierter Schreibweg. Deployment Target macOS 27.0, Swift-6-Sprachmodus, eigene Swift-Targets ohne externe Dependencies.

## Enthalten

- Native SwiftUI-Oberfläche mit einem vollständigen lokalen Dateitest.
- Kurzlebiges CLI-Tool ausschließlich mit `--demo`, ohne frei wählbaren Zielpfad. Ausführung als Root wird abgewiesen.
- Requestmodell mit Version, UUID, erwartetem SHA-256 und einer von zwei festen Beispieloperationen. Zusatzfelder, doppelte Schlüssel (auch mit Unicode-Escapes), unbekannte Operationen, fehlerhafte Digests und Übergröße werden abgewiesen.
- Private Wegwerfdatei, Vorherkopie, Journal, Receipt und Rekonstruktion simulierter Unterbrechungen. Fremde Änderungen werden nicht automatisch rückgängig gemacht.
- Optionaler OS-Dialogtest mit festem AppleScript `do shell script "/usr/bin/id -u" with administrator privileges`. Er startet ausschließlich Apples `id`, schreibt keine Datei und ist ohne ausdrückliches VM-Testargument deaktiviert.
- Swift-Packager für `.app` und ZIP mit lokaler Ad-hoc-Signatur und Hardened Runtime; keine Account-/Team-Konfiguration.

## Ausführen

Vom Repository-Root, normale unprivilegierte Shell:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules swift test --package-path Experiments/AuthorizationProbe --scratch-path /tmp/machosts-phase0-build --cache-path /tmp/machosts-phase0-cache --disable-sandbox
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules swift build --build-system native -c release --package-path Experiments/AuthorizationProbe --cache-path /tmp/machosts-phase0-cache --disable-sandbox
Experiments/AuthorizationProbe/.build/arm64-apple-macosx/release/MacHostsProbeTool --demo
CLANG_MODULE_CACHE_PATH=/tmp/machosts-phase0-modules SWIFTPM_MODULECACHE_OVERRIDE=/tmp/machosts-phase0-modules Experiments/AuthorizationProbe/.build/arm64-apple-macosx/release/PackageProbe
```

Der genaue Binärpfad lässt sich mit `swift build --build-system native -c release --package-path Experiments/AuthorizationProbe --show-bin-path` abfragen. Hier wurde der bestehende native SwiftPM-Builder als lokale Ausweichlösung verwendet: Der neue Standardbuilder scheiterte unter der Ausführungs-Sandbox beim dSYM-Schritt. Der native Builder ist selbst als deprecated markiert; dies ist kein dauerhafter Buildstandard für das Produkt. `--disable-sandbox` deaktiviert nur die zusätzliche SwiftPM-Manifest-/Plugin-Sandbox innerhalb der bestehenden Ausführungsumgebung, nicht SIP, Gatekeeper oder macOS-Sicherheitsfunktionen.

Der Packager erzeugt `Output/MacHostsAuthorizationProbe.app` und `.zip`. Bestehende App-Artefakte werden nicht überschrieben. Bei einem erneuten Build altes Artefakt bewusst umbenennen oder entfernen. Die eingebettete Demo-Binary wird von der App nicht als Root aufgerufen.

Formatprüfung:

```sh
xcrun swift-format lint --strict --recursive Experiments/AuthorizationProbe/Sources Experiments/AuthorizationProbe/Tests Experiments/AuthorizationProbe/Package.swift
```

## Nur im VM-Testlauf

App zuerst ohne Zusatzargument starten, lokalen Dateitest ausführen, danach separat in der Wegwerf-VM:

```sh
open MacHostsAuthorizationProbe.app --args --enable-vm-auth-probe
```

Das Argument ist eine Bedienhürde, kein technischer Beweis, dass eine VM vorliegt. Der Nutzer/Tester muss die VM-Umgebung vorher bestätigen. In der Oberfläche den Systemdialog bewusst starten. Erfolg und Abbruch separat dokumentieren; keine Kennwörter protokollieren. Dieser Test belegt höchstens die Autorisierung von Apples `id`, nicht den sicheren Start eines eigenen Swift-Tools.

## Grenzen

Fixture, Backup, Journal und Receipt werden in begrenzten Chunks gelesen; ab mehr als 1 MiB bricht der Store nach höchstens Limit plus einem Prüfbyte ab. Auch ein geplanter Zielinhalt über 1 MiB wird vor Backup und Write abgewiesen. Tests prüfen die Grenze, unveränderte Dateien bei Abweisung und den Erhalt eines offenen Journals bei übergroßem Recovery-Backup. Dies ist keine Messung des gesamten Prozessspeichers.

Lesen öffnet mit `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` und prüft anschließend per `fstat` am geöffneten Deskriptor Dateityp, Linkzahl und Eigentümer. Ein Symlink im letzten Pfadbestandteil wird nicht verfolgt, ein FIFO blockiert nicht beim Öffnen und nicht reguläre Dateien werden vor dem Lesen abgewiesen. Der Handle wird auch bei Validierungs-/Lesefehlern geschlossen. Tests prüfen Verzeichnisse, FIFOs, verwaiste Symlinks sowie Symlink-/Hardlinkziele und verlinkte Recovery-Artefakte. Das fixiert den gelesenen Inode, garantiert aber weder unveränderliche Inhalte bei konkurrierenden In-place-Writes noch sichere Elternverzeichnisse.

Der Fixture-Store ist ausschließlich für unprivilegierte Tests bestimmt: keine fsync-/Stromausfallgarantie, keine sichere FD-basierte Root-Pfadbehandlung, keine ACL-/xattr-Erhaltung, keine Mehrprozesssperre, keine dauerhafte Replay-Datenbank, keine echten Prozess-Kill-Tests. Wirebytes müssen über `ProbeRequest.decode` gelesen werden: Eine begrenzte Prüfung des flachen JSON-Objekts erkennt doppelte Schlüssel vor dem typisierten Decoding. Direktes `JSONDecoder.decode(ProbeRequest.self, …)` bietet diesen Schutz nicht. Dies belegt weder eine sichere Requestübergabe noch deren Digestbindung. Die beobachteten Unterbrechungen sind Fehlerinjektionen, kein Nachweis über Crash/Powerloss. Auch die Wiederherstellung der Fixture durchläuft jetzt Backup, Journal, Ersetzen, Readback und Receipt. Das Journal unterscheidet Apply und Restore mit einem festen Enum; daraus ergeben sich ausschließlich feste interne Artefaktnamen. Restore sichert den aktuellen Stand in `restore-before.bin` und schreibt `restore-receipt.json`; `original.bin` und das ursprüngliche Apply-Receipt bleiben erhalten. Recovery rekonstruiert beide Operationen anhand ihrer jeweiligen Vorher-/Nachher-Digests. Tests decken fünf Unterbrechungspunkte, erneutes Restore nach Recovery, No-op, veraltete Vorschau, beschädigtes Restore-Backup und externe Änderungen ab. Es bleiben simulierte Unterbrechungen innerhalb derselben Sitzung; Neustart und dauerhafte Speicherung sind damit nicht bewiesen. Das interne Journalformat wurde geändert; es gibt keine Migration alter Experimentjournale und keine Wiederaufnahme alter Sitzungsverzeichnisse.

Beim Schreiben bleibt die Lücke zwischen `lstat` und Ersetzen offen. Auch die neue Leseprüfung liefert keinen vollständigen Schutz vor einem gleichzeitig handelnden Prozess desselben Nutzers: Elternverzeichnisse, Metadatenänderungen und konkurrierende Writes sind nicht abgesichert. Gerade deshalb lehnen die ausführbaren Demos Root ab. Keine Bestandteile dieses Stores ohne neue Prüfung in das privilegierte Produkt übernehmen.

Die Journal-Anwesenheitsprüfung verwendet `lstat`: Auch ein verwaister Journal-Symlink sperrt Apply und Restore; Recovery weist ihn ab, statt die Sitzung als sauber zu melden. Bei tatsächlichen Änderungen prüft Commit die festen Backup- und Receiptziele vor dem ersten Write auf regulären Dateityp, eigenen Eigentümer und genau einen Hardlink. Bereits vorhandene unsichere Artefakte werden damit vor Änderungen an Fixture oder Backup abgewiesen. Tests decken Symlinks einschließlich verwaister Ziele, Hardlinks, Verzeichnisse und FIFOs ab. Dies ist eine Vorabprüfung bestehender Einträge; spätere konkurrierende Änderungen bleiben durch die oben genannte Schreib-Lücke möglich. Ein No-op erzeugt weiterhin keine Transaktionsartefakte.

Beim Anhängen an eine Datei ohne letztes LF bleibt der notwendige Trenn-LF beim späteren Blockentfernen erhalten; nur ein Vollbackup stellt die ursprünglichen Bytes exakt wieder her. Das spätere Produkt muss Trennbyte-Herkunft dauerhaft nachhalten, wenn es diesen LF beim Entfernen ebenfalls zurücknehmen soll.

Der Prototyp greift nie auf die Systemhosts-Datei zu. Gate 0 bleibt offen, bis geschützter Toolstart, Requestübergabe und echte VM-Integration nachgewiesen sind. Siehe [ADR 0001](../../docs/decisions/0001-privileged-write.md) und [Phasenbericht](../../docs/verification/phase-0.md).

Gespeicherte Transaktionsdaten werden vor Recovery und Restore zusätzlich auf Konsistenz geprüft: kanonische SHA-256-Digests, unterschiedliche Vorher-/Nachher-Digests und kein gespeicherter No-op. Beschädigtes JSON führt zu `recoveryRequired`. Bei ungültigem Journal bleiben alle Artefakte unverändert und weitere Transaktionen gesperrt. Diese Prüfung liefert keine Authentizitätsgarantie; die festen Journal-/Receipt-Schemata werden vor Codable auf zusätzliche, fehlende und doppelte Schlüssel einschließlich Unicode-Escapes sowie unzulässige Werttypen und Verschachtelung geprüft. Ungültige Daten lösen `recoveryRequired` vor weiteren Writes aus; Tests belegen unveränderte Artefakte bei Abweisung sowie gültige escaped Schlüssel und jede Abschneidestelle. Die aktuelle Debug-Suite umfasst 36 Testfunktionen; vorhandene Output-Artefakte stammen weiterhin aus dem früheren Paketierungslauf.

Leser und Schreibvorabprüfung weisen reguläre Dateien mit POSIX-Gruppen- oder Fremdschreibrechten (`mode & 0022 != 0`) als `unsafeFile` ab. Dies gilt für Fixture und Transaktionsartefakte; vorhandene unsichere Dateien werden nicht durch chmod repariert. Tests prüfen unveränderte Bytes und Artefaktnamen bei Apply-/Restore-Abweisung sowie den Erhalt offener Journale bei Recovery. Modi 0400, 0600 und 0644 bleiben lesbar. Diese Prüfung untersucht keine ACLs und verhindert keine späteren Rechteänderungen durch konkurrierende Prozesse. Die privaten Elternverzeichnisse bleiben eine Voraussetzung des Experiments.
