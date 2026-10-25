# MacHosts – phasenweiser Umsetzungsplan

Stand: 25. Oktober 2026. Produktrichtung bestätigt. **Phase 0: lokale Vorbereitung abgeschlossen, Requestprüfung, Größenlimits, deskriptorgeprüftes Lesen, journalisierte Fixture-Wiederherstellung, Vorabprüfung unsicherer Transaktionsartefakte, Abweisung fremdbeschreibbarer Dateien und Konsistenz- und eindeutige JSON-Schemaprüfung gespeicherter Transaktionsdaten ergänzt; privilegierte Nachweise ausstehend.** VM-Tests wurden auf Nutzerwunsch vorerst vertagt. Gate 0 ist gemäß [ADR 0002](decisions/0002-deferred-gate-0.md) ausdrücklich zurückgestellt; Phasen 1–3 sind implementiert und lokal geprüft; Gates 2 und 3 lokal bestanden, formaler Clean-Checkout-/CI-Nachweis aus Phase 1 offen. Phase 4: Apply-Koordination, persistente App-Absicht, Schema-2-Migration, Receipt-/Readback-Recovery sowie interner Systemtransaktionskern mit privaten Dateifixtures lokal implementiert und geprüft; unprivilegierte Dateibeobachtung einschließlich Inode-/Verzeichniswechsel und explizite Diagnose verwaister App-Absichten mit gemeinsamer Recovery-Sperre an privaten Fixtures geprüft; produktive Dateitransaktion und Gate 4 bleiben offen (siehe [Phase 4](verification/phase-4.md)). Phase 5: lokaler Profilworkflow mit nativem Editor, Autosave, Papierkorb, Ordnerverwaltung, profilübergreifender Suche sowie Editorfarben/Zeilennummern implementiert; Teilnachweis in [Phase 5](verification/phase-5.md), Gesamtgate offen. Siehe [Phase-0-Bericht](verification/phase-0.md); das Gate bleibt offen.

## Arbeitsweise und Gate-Regeln

Fachliche Abhängigkeiten beachten; die pauschale Reihenfolgesperre durch Gate 0 entfällt gemäß ADR 0002. Jede Phase endet mit Code/Artefakten, geeigneter Verifikation, einem Eintrag in `docs/verification/phase-N.md` und aktualisiertem Status unten. Ein Nachweis nennt Umgebung, genaue Befehle/Aktionen, Ergebnis, relevante Logs/Artefakte und verbleibende Risiken. „Nicht ausgeführt“ ist weder „bestanden“ noch ein automatischer Fehler des Produkts.

Pro Coding-Run möglichst viele zusammenhängende Schritte und nach bestandenen Gates mehrere Phasen abschließen. Nicht nach jeder Einzelkorrektur stoppen. Tests, Builds und Formatprüfungen erst an größeren fachlichen Abschlüssen bündeln; erforderliche Gate-Prüfungen bleiben vor abhängigen Arbeiten verbindlich. Die detaillierten Regeln für schnelle, token-effiziente Durchführung stehen in [CODEX-ANWEISUNGEN.md](CODEX-ANWEISUNGEN.md#umfang-tempo-und-token-effizienz). Diese Arbeitspräferenz ändert weder den aktuellen Gate-Status noch die Vertagung der VM-Tests.

Bei fehlender Testumgebung dürfen unabhängige Arbeiten vorbereitet werden; abhängige Gates bleiben offen. Insbesondere lässt sich das Gate für privilegierte Systemintegration nicht durch einen Mock ersetzen. Die lokale Hosts-Datei des Arbeitsrechners einschließlich Rechte/Metadaten darf durch Coding, Tests, Demos oder Hilfsskripte niemals verändert werden. Tatsächliche Systemwrites ausschließlich in einer dafür vorbereiteten bestätigten wegwerfbaren macOS-27-VM; gezielte Tests dort sind Teil des späteren Implementierungsauftrags.

Sicherheitsverträge aus [ARCHITEKTUR.md](ARCHITEKTUR.md) gelten in jeder Phase. Ein echtes Produkt-/Architekturhindernis wird mit konkreten Alternativen vorgelegt. Routineentscheidungen innerhalb dieser Verträge selbst treffen, dokumentieren und weiterarbeiten.

## Zurückstellung von Gate 0

Phasen 1–3 können vollständig, Phasen 4–7 mit privaten Fixtures bzw. nicht verfügbarem Systemwriter entwickelt werden. Deren fachliche Abhängigkeiten bleiben bestehen; Teilabschlüsse sind kein bestandener Integrationsnachweis. Gate 0 bleibt verbindlich vor produktivem privilegiertem Betrieb, Integrationsabschluss von Phase 4 sowie Gesamtfreigaben in Phasen 8 und 9. VM-Tests bleiben vorerst vertagt.

## Status

| Phase | Ergebnis | Status | Abhängig von |
| --- | --- | --- | --- |
| Planung | Recherche, Dialogentscheidungen, Architektur und Arbeitsauftrag | abgeschlossen | — |
| 0 | accountloser sicherer Schreibweg nachgewiesen | lokale Vorbereitung fertig; Gate offen, VM vertagt | Planung |
| 1 | reproduzierbares Projekt und Prüfkommandos | implementiert; lokale Checks bestanden, Clean-Checkout-/CI-Nachweis offen | Planung; Gate 0 zurückgestellt |
| 2 | Parser, Profile, Konflikte und Komposition | implementiert; Gate 2 lokal bestanden ([Nachweis](verification/phase-2.md)) | 1 |
| 3 | Workspace-Speicher und unprivilegierte Recovery | implementiert; Gate 3 lokal bestanden ([Nachweis](verification/phase-3.md)) | 2 |
| 4 | produktiver Apply-/Backup-/Recovery-Ablauf | Teilabschluss: App-Koordination, privater Dateikern, App-Save-Abbrüche, getrennte Worker und dauerhafte Stilllegung verwaister Absichten an Fixtures geprüft; Gate offen | 2, 3; Gate 0 für echte Integration |
| 5 | native App, Editor und Hauptabläufe | Teilabschluss: lokale Profile, Ordner und Suche implementiert; native Abnahme und Gesamtgate offen | 4 |
| 6 | Menüleiste, Login-Start und Systemdiagnose | offen | 5 |
| 7 | Remote-Profile und Migration/Export | offen | 3, 5 |
| 8 | Härtung, Zugänglichkeit, Performance und Beta | offen | 6, 7 |
| 9 | Release-Artefakt und Produktionsabnahme | offen | 8 |

## Phase 0 – Machbarkeit vor Produktimplementierung

**Ziel:** beweisen, dass die gewünschte accountlose Distribution und ein vertretbar sicherer privilegierter Schreibweg zusammen funktionieren. Es genügt kein sichtbarer Admin-Dialog.

**Aufgaben für Codex:**

1. Lokal vorhandene Toolchain/SDK und dokumentierte Autorisierungswege prüfen, Quellen aus der Recherche bei Bedarf aktualisieren. Alle Tests zunächst gegen Wegwerfdateien und im privilegierten Teil nur in der Test-VM planen.
2. Minimalen Swift-Prototyp unter `Experiments/AuthorizationProbe/` erstellen: unprivilegierte Oberfläche, enges Requestmodell, kurzlebiges Swift-Tool, Ad-hoc-Build ohne Team und ohne Account. Kein produktiver Editor, kein Profilmanagement.
3. OS-Autorisierungsbrücke auf macOS 27 testen. Pfade mit Leerzeichen, Quotes und Unicode berücksichtigen. Profilinhalt ist ausschließlich Daten; Injection-Versuche dürfen keine Befehle erzeugen. Verwendete Shell-/AppleScript-Ebene exakt dokumentieren und klein halten.
4. Herkunft des privilegiert ausgeführten Codes und seiner Libraries absichern. Ersetzbare Binary nach Hashprüfung, manipulierte Requests, Symlinktausch, Replay und TOCTOU ausdrücklich untersuchen. Installationsort oder ein Bundle-Identifier allein sind kein Vertrauensbeweis. Falls geschütztes Staging nötig ist, dessen gesamten Bootstrap und Cleanup nachvollziehbar entwerfen.
5. Abbruch, falsche/fehlende Berechtigung, Timeout, veränderter Request und Prozessende untersuchen. Kennwort ausschließlich im Systemdialog; keine eigene Kennworteingabe oder Speicherung.
6. Gegen eine VM-Hosts-Datei No-op, Hinzufügen, Entfernen, Readback und Wiederherstellung ausführen; Originalbytes anschließend verifizieren. Quarantänisierten ZIP-Download bzw. realistische Quarantäne-Eigenschaften und die individuelle Erststartfreigabe einbeziehen.
7. `docs/decisions/0001-privileged-write.md` schreiben: geprüfte Optionen, gewählter Mechanismus, Threat-Grenzen, Nachweise, bekannte Restgefahren und nicht unterstützte Fälle. Offene Sicherheitslücken nicht als akzeptiertes Restrisiko deklarieren.

**Gate 0:** accountlos gebauter Prototyp läuft auf einer frischen macOS-27-VM, weist den eng begrenzten sicheren Write samt Abbruch/Recovery nach und benötigt weder veraltetes `AuthorizationExecuteWithPrivileges` noch breites `sudoers`, persistente Hosts-Schreibrechte oder eine Root-GUI. Ausführbare Herkunft und Requestintegrität sind nachvollziehbar abgesichert. Bei fehlendem Nachweis Status „nicht bestanden“ und Alternativen im Dialog klären. Unabhängige Produktimplementierung ist gemäß ADR 0002 erlaubt. Ein nicht verfügbarer Systemwriter darf keinen Erfolg simulieren.

## Phase 1 – Projekt, Toolchain und Qualitätsbasis

**Ergebnisse:** `MacHosts.xcodeproj`, lokale Package-Struktur gemäß Architektur, App- und Tool-Target, gemeinsame Schemes, minimale native Startansicht, String Catalog und Testtargets. Lizenzdatei MIT mit korrekter Copyright-Angabe; Bundle-ID als dokumentierte Projektkonstante, ohne Team-ID-Abhängigkeit.

**Aufgaben:**

- SDK/Deployment Target 27.0, arm64, Swift-6-Sprachmodus und Strict Concurrency prüfen. UI-Default-Isolation bewusst setzen; Core/Systemmodule nicht versehentlich komplett an den Main Actor binden.
- Automatisches Signing/Teamzwang ausschließen; Ad-hoc-Einbettung des Swift-Tools von innen nach außen korrekt konfigurieren. Notwendige Entitlements und Hardened Runtime nachweisen.
- `swift-format`-Konfiguration einchecken; Warnungen in eigenem Code beheben. Keine Dependency nur für bequeme Projektgenerierung.
- Exakte lokale Build-/Test-/Formatbefehle in `docs/ENTWICKLUNG.md` festhalten. Keine `sudo`- oder Kennwortkommandos in der normalen Entwicklerpipeline.
- CI-Konfiguration für verfügbare macOS-/Xcode-Runner ergänzen. Wenn die geforderte Version dort fehlt, ehrlichen offenen Infrastrukturpunkt dokumentieren und lokale Prüfung weiter ermöglichen; Toolchain nicht still downgraden.

**Verifikation/Gate 1:** Clean Checkout ohne eingeloggten Apple-Account baut App und Tool; App startet; minimale Core-Tests laufen; Formatprüfung läuft. Shared Schemes und Testpläne sind mit CLI nutzbar. Build- und Signaturprüfung liefern dokumentierte Ergebnisse. Ein erfolgreicher Build alleine bestätigt noch keine Systemintegration.

## Phase 2 – Parser und reine Fachlogik

**Ergebnisse:** `HostsCore` mit zeilentreuem Parser, typisierten Profilen, deterministischer Komposition, eigener Markerlogik, Konfliktanalyse und immutable `ApplyPlan`.

**Aufgaben:**

- Modelle und Normalisierung nach Architektur umsetzen. Eintragsschalter über das festgelegte Profil-Kommentarpräfix abbilden; gewöhnliche Kommentare bleiben Kommentare.
- Präfix/Suffix außerhalb des eigenen Blocks bytegenau erhalten; Zeilen ohne abschließenden LF und unterschiedliche Zeilenenden behandeln. Fremde Marker bleiben fremd.
- Ungültige Daten explizit diagnostizieren, keine automatische Reparatur mit Datenverlust. IPv4/IPv6, gleiche/verschiedene IPs, Aliaslisten und Herkunft prüfen.
- Übernahme bei widersprüchlichen Belegungen, kaputten Markern oder Größenüberschreitung blockieren. Aktive fremde Systemeinträge in Konflikte einbeziehen.

**Verifikation:** parametrisierte Swift-Testing-Fixtures für gültige/ungültige Zeilen, CRLF/LF, Leerdatei, NUL, Unicode-Kommentare, IP-Sonderfälle, doppelte Marker, eingeschleuste Marker, Profilnamen mit Zeilenumbrüchen und deaktivierte Zeilen. Invarianten prüfen: deterministische Ausgabe, No-op-Idempotenz, bytegenauer Fremdbereich, Remove-Operation berührt keine fremden Bytes. Generierte Zufallsfälle ergänzen, soweit sie diese Invarianten tatsächlich prüfen.

**Gate 2:** Parser/Composer können ohne UI, Root und Netzwerk getestet werden. Alle relevanten Invarianten bestehen; keine unaufgelösten Mehrdeutigkeiten im Dateiformat.

## Phase 3 – Persistenz und Workspace-Recovery

**Ergebnisse:** `WorkspaceStore`, atomare JSON-Snapshots, versioniertes Schema, lokaler Papierkorb, debounced Autosave und Start-Recovery für App-Daten.

**Aufgaben:**

- Aktuelle API über typisierte DTOs, Actor-Grenzen und Revisionen gestalten; keine UI-Bindings direkt an Dateischreibfunktionen.
- Snapshot in sichere temporäre Datei desselben Verzeichnisses schreiben und atomar veröffentlichen; unabhängige App-Instanzen serialisieren oder den zweiten Writer explizit ablehnen.
- Beschädigte oder neuere Formate sichern/schreibgeschützt öffnen. Keine Rücksetzung auf leere Daten als Fehlerbehandlung. Migration erst nach Backup.
- Letzten angewendeten Snapshot getrennt vom Entwurf speichern und auf einen Receipt beziehen.

**Verifikation:** Neustart-Roundtrip, Migration, abgeschnittenes JSON, unbekannte Version, Disk-full-/Permission-Fehlerinjektion, parallele Änderungen, Abbruch zwischen Temp-Write und Rename. Keine verlorenen bestätigten Entwürfe und kein Erfolg nach fehlgeschlagenem Save.

**Gate 3:** lokale Daten sind nach Unterbrechung rekonstruierbar; Entwurf und angewendeter Zustand werden nicht verwechselt. Tests bleiben im temporären Workspace.

## Phase 4 – Produktiver Apply, Backups und Recovery

**Teilstand:** Apply-Zustandsmaschine und App-Recovery mit privatem Workspace und explizitem Testadapter verifiziert. Zusätzlich interner Transaktionskern mit enger Blockmutation, tatsächlichen privaten Backups/Journals, Rename/Readback und Fehler-Recovery geprüft. Der private Dateiadapter ist zusätzlich durchgehend an den Koordinator angebunden; acht echte Prozessabbruch-/Neustartfälle sowie externe/beschädigte Recoverydaten und Prozesslocks sind geprüft. Neun Prozessabbrüche während Absichts-/Ergebnis-/Recovery-Save und vier unabhängige App-/Worker-Lebenszyklen einschließlich SIGKILL sind ebenfalls an privaten Fixtures geprüft; neuere Entwürfe bleiben erhalten, laufende Worker verhindern vorzeitige Recovery. Unprivilegierte Dateibeobachtung mit Verzeichnis-/Dateiüberwachung, Digestabgleich und expliziten Lesefehlern ist an privaten Fixtures geprüft. Die App-Anbindung mit Receipt-/Intentabgleich, sichtbaren Lesefehlern sowie Wake-/Neustartaktionen ist implementiert; Modelltests, Format und Release-Build bestanden, native UI-/Wake-Abnahme offen. Verwaiste App-Absichten haben jetzt eine explizite Diagnose (fehlendes Journal, aktiver Worker, unklarer Ausgang) und bleiben ohne unabhängige terminale Nachweise erhalten. Die Recovery ist über mehrere Koordinatoren hinweg serialisiert; Dateivergleich und fehlende Nachweisprüfung dieses Builds sind sichtbar. Private Evidenzmatrix, Prozessnachweise und Erhalt älterer Receipts/neuerer Entwürfe geprüft. Die explizite Stilllegung journal-loser Absichten mit dauerhafter Replay-Sperre, frischem Vorher-Digest und sieben neuen Prozessabbruchfällen ist gemäß ADR 0003 ausschließlich an privaten Fixtures geprüft. Kein neuer Receipt oder historischer Nicht-Commit wird daraus abgeleitet; die Produktionsoberfläche bleibt gesperrt. Kein produktiver Systemadapter oder Nachweis privilegierter Backups; Gate 4 bleibt offen. Details: [Phase 4](verification/phase-4.md).

**Ergebnisse:** `ApplyCoordinator`, produktiver Autorisierungsadapter aus ADR 0001, enges Toolprotokoll, Backup- und Receiptverwaltung, sichere Dateitransaktion, externe Änderungsbeobachtung.

**Aufgaben:**

- Verträge des Prototyps in kleine überprüfbare Swift-Komponenten übertragen; Experimentcode nicht ungeprüft als Produktcode übernehmen.
- Preflight, unveränderliche Vorschau, Autorisierung, privilegierte Revalidierung, Backup, Journal, Rename und Readback ausführen. Dieselben Regeln gelten für Ausschalten und kontrollierte Rücksicherung.
- Transaktionszustände über App-Neustart rekonstruieren. Hash-/Revisionsänderungen während `await` erkennen; Zweitklicks und mehrere Prozesse serialisieren.
- Feste DNS-Cache-Operation getrennt prüfen. Istwert der Systemauflösung über den Systemresolver prüfen; keine `dig`-Ergebnisse als Hosts-Test verwenden.
- Keine beliebigen Pfadparameter in der Produktionsschnittstelle. Temporäre Testpfade nur intern über Testkomponenten, kein versteckter Root-CLI-Schalter für beliebige Ziele.

**Verifikation:** normale Integrationstests an Testdateien; zusätzlich VM-Matrix mit echten Zielpfaden: Erfolg, No-op ohne Auth, Nutzerabbruch, Permissionfehler, Backupfehler, veralteter Plan, externe Mutation, fehlender/defekter Marker, manipulierte Requests, Symlink/Hardlink, Disk full, Ende vor/nach Rename, Ende nach Write vor App-Save, widersprüchlicher Readback und Cache-Flushfehler. VM-Originalzustand bytegenau wiederherstellen. Mehrere Benutzer und Update des eingebetteten Tools prüfen.

**Gate 4:** falscher angewendeter Status und stiller Verlust fremder Daten sind durch Tests ausgeschlossen, soweit die dokumentierten Verträge reichen. Journal-/Receipt-Recovery ist für jeden Commit-Unterbrechungspunkt belegt. Restfenster gegenüber nicht kooperierenden Fremdschreibern ausdrücklich dokumentiert. Kein offener schwerer Fehler an der Privilegiengrenze.

## Phase 5 – Native Haupt-App und Editor

**Teilstand:** Gemeinsames `ProfileWorkspaceModel` mit Profil-Neuanlage, Umbenennen, lokaler Duplikation, gewünschter Aktivierung, Reihenfolge, Papierkorb und inaktiver Wiederherstellung. Native `NSTextView`-Brücke mit Undo und Findbar, Parserdiagnostik und digestgebundenen Eintragsschaltern. Sichtbarer lokaler Speicherstatus, Fehler/Retry und Speichern vor regulärem Beenden. Deutsch/Englisch ergänzt. Ordnerverwaltung mit validierter Hierarchie, Erhalt der Profile beim Entfernen und stabiler Geschwisterreihenfolge. Profilübergreifende literale Suche auf einem Dienstactor, begrenzte Trefferliste und digestgesicherter Sprung zur nativen Textauswahl. 111 Pakettests, Formatprüfung, Release- und Debug-Testbuild bestanden. Syntaxfarben und Zeilennummern mit parsergestützten UTF-16-Bereichen und temporären Layoutattributen ergänzt; tatsächliche SwiftUI-/AppKit-Brücke einschließlich Undo/Redo, 10.000 Zeilen und Hell/Dunkel in-process geprüft. XCUITest-Zugang weiterhin ungeklärt, neue UI-Tests nur gebaut. Kein Systemwrite oder simulierter Apply-Erfolg; Systeminhaltsansicht und Preview-/Recovery-Oberfläche bleiben offen. Nachweise und Grenzen: [Phase 5](verification/phase-5.md). Gate 5 ist nicht bestanden.

**Ergebnisse:** vollständiger lokaler Arbeitsablauf, SwiftUI-Hauptfenster, Sidebar, `NSTextView`-Brücke, Profil-/Systemansichten, Vorschau und verständliche Fehler.

**Aufgaben:**

- Kleine Feature-Views für Profile, Editor, Preview, Recovery und Settings. Gemeinsames `AppModel` und Services injizieren; keine generische State-Management-Bibliothek.
- Profil-/Ordneraktionen, Reihenfolge und Papierkorb umsetzen. Native Fokus-/Auswahllogik und Undo/Redo erhalten.
- Diagnostik und Zeilenschalter aus dem Parser ableiten. Remote-Inhalte erkennbar schreibgeschützt; lokales Duplikat als Bearbeitungsweg.
- Lokales Autosave und „Noch nicht angewendet“ sichtbar machen. Aktive Profile mit lokal bearbeitetem Text bleiben in der Systemdatei unverändert, bis bewusst übernommen wird.
- Übernahme zeigt den gesamten eingefrorenen Plan, Konfliktursachen und systemweite Wirkung. Bei Änderung während der Vorschau neu planen.
- Deutsch/Englisch von Beginn an über String Catalogs; keine hardcodierten Textkopien in Services. Native Commands für Neu, Suche, Undo und Übernehmen, ohne Tastenkonflikte mit Texteingabe.

**Verifikation:** XCUITest mit injizierter, unprivilegierter Systemumgebung für Create → Edit → Toggle → Preview → Apply → Disable → Recovery. Abbruch und Fehler müssen den richtigen Istzustand behalten. Manuelle native Editorprüfung für Undo, Auswahl, große Zwischenablage, Suchtreffer, Zeilenschalter und Tastaturnavigation.

**Gate 5:** vollständiger lokaler Hauptworkflow ohne Terminal bedienbar; kein Platzhalter im Kernablauf; UI und echte Systemintegration bleiben separat belegt.

## Phase 6 – Menüleiste, Login und Diagnose

**Ergebnisse:** `MenuBarExtra`, verlässlicher Fensterschließen-/Wiederöffnen-Lebenszyklus, optionaler Autostart und Diagnoseansicht.

**Aufgaben:**

- Alle Menüaktionen benutzen den gleichen `ApplyCoordinator`. Menü zeigt angewendete Profile und Entwurfsabweichungen separat.
- Hauptfenster schließen lässt die App für die Menüleiste laufen; „Beenden“ beendet sie, ohne Hosts zurückzusetzen. Beim ersten Bedarf verständlich erläutern, keine wiederholten Warnmodals.
- Schnellaktionen mit Vorschau und Admin-Freigabe; vorhandene ungespeicherte/noch nicht angewendete Änderungen transparent berücksichtigen.
- `SMAppService.mainApp` für freiwilligen Login-Start im accountlosen Build lokal nachweisen; Systemstatus statt eigenen Wunschboolean anzeigen. Verschieben/Update sowie OS-seitiges Abschalten testen.
- Systemdateiänderungen einschließlich atomarem Ersetzen erkennen. Resolverausgabe, letzte Übernahme und DNS-Cache-Status sachlich anzeigen; keine Garantie über Browser-/Proxy-Caches.

**Gate 6:** Menü-/Fensteraktionen erzeugen keine divergierenden Zustände. Schließen, Beenden, Login, Sleep/Wake, manuelle externe Änderung und App-Update sind nachvollziehbar. Kein Autostart oder Root-Prozess ohne bewusste Einrichtung.

## Phase 7 – Remote und Austausch/Migration

**Ergebnisse:** begrenzter HTTPS-Download, letzter gültiger Cache, optionale Aktualisierung während laufender App, eigenes Exportformat und dokumentierter SwitchHosts-Import.

**Aufgaben:**

- Limits, TLS, Redirects, Stale-Response-Schutz und Abbruch gemäß Architektur implementieren. ETag/304, Offline und ungültige Antworten behandeln.
- Änderungsvorschau für Remote-Updates und bewusste Systemübernahme; niemals Auto-Apply.
- Eigene Fixtures für MacHosts-JSON und `.hosts`; Import ist lokal, deterministisch und ohne Netzwerk-/Systemnebeneffekte.
- Offizielle SwitchHosts-Exporte für repräsentative v4-/v5-Stände untersuchen, Format/Version/Quelle der Testdaten dokumentieren. Gewünschtes V1-Ziel: ein repräsentativer v4-Export und der recherchierte v5-Export; konkrete unterstützte Versionen erst nach Fixtures zusagen. Keine Übernahme großer fremder Datensammlungen als Testbehelf.
- Ordner, Texte und URLs importieren, IDs remappen und aktive Zustände deaktivieren. Gruppen nur mit eindeutiger Auflösung; Unbekanntes, Zyklen oder inkompatible Formate mit präzisem Bericht behandeln. Bestehenden SwitchHosts-Systemblock nicht anfassen.
- Preview mit append/replace, Backup vor replace, sicherer Reimport und nachvollziehbare Warnungen; kein unbemerktes Abschneiden bei Limits.

**Verifikation:** lokale URLSession-Testserver/Stubs für Timeout, Übergröße, Redirectkette, TLS-Fehler, veraltete Antwort und Löschung während Download. JSON-Fehlerinjektion, unbekannte Version, ID-Kollision, Zyklus, verschachtelte Ordner und Roundtrip prüfen. Ein echter öffentlicher HTTPS-Abruf ergänzt die Integration, ersetzt die deterministischen Tests nicht.

**Gate 7:** Remote-Fehler zerstören keinen gültigen Stand und lösen keine Systemänderung aus. Alle unterstützten Importversionen sind mit Fixtures belegt und im Nutzerhandbuch genannt. Keine pauschale Behauptung vollständiger SwitchHosts-Kompatibilität.

## Phase 8 – Härtung und Beta-Abnahme

**Ergebnisse:** überprüfte Fehlergrenzen, zugängliche native UI, dokumentierte Performance, vollständige Recovery- und Betriebsanleitung.

**Aufgaben:**

- Privilegierte Grenze, Import und Remote-Eingänge noch einmal anhand der konkreten Implementierung prüfen. Keine bloße Wiederholung dieser Architektur als Sicherheitsnachweis.
- Vollständige Fehlermatrix und kritische Crashpunkte wiederholen; offene Datenverlust-/Privilegienfehler beseitigen.
- VoiceOver, gesamte Tastaturbedienung, Fokus nach Sheets, hoher Kontrast, reduzierte Transparenz/Bewegung, Hell/Dunkel, deutsche längere Texte prüfen.
- Messbudgets aus der Projektskizze an Release-Builds mit Geräte-/Datensatzangaben prüfen. Keine Daten- oder UI-Funktion zugunsten einer kleinen Binärdatei entfernen.
- Lokalen Offlinebetrieb, Leerlauf ohne Downloads, Log-Redaktion, Dateirechte, Retention und Diagnoseexport prüfen. Aktuelle Abhängigkeiten/Lizenzen falls vorhanden inventarisieren.
- `docs/BENUTZERHANDBUCH.md` erstellen: Erststart, Aktivierung, Konflikte, Remote, Backup, TLS-/Resolvergrenzen, Migration und vollständiges Entfernen.

**Gate 8:** kein bekannter releaseblockierender Crash, keine offenen Datenverlust-/Rechtefehler, keine unbestätigten Erfolgsmeldungen. Kritische Abläufe zugänglich, Ressourcenverbrauch gemessen, bekannte harmlose Grenzen konkret dokumentiert. Tests, die nie liefen, bleiben offen.

## Phase 9 – Paketierung und Produktionsrelease

**Ergebnisse:** Release-Build, ad-hoc-signiertes App-Bundle im ZIP (DMG optional), SHA-256-Prüfsumme, Release Notes und vollständiger Freigabenachweis. V1 bietet keinen automatischen Updater.

**Aufgaben:**

- Build/Paketierung aus sauberem Projektstand mit festgehaltener Xcode-Version reproduzierbar ausführen. Keine Behauptung bitidentischer Builds ohne Nachweis.
- Eingebettete Binaries und abschließendes Bundle korrekt signieren; Signaturintegrität prüfen. Erwartete Gatekeeper-Ablehnung ohne Developer ID von einer beschädigten/ungültig signierten Binary unterscheiden.
- Tatsächlichen Download mit Quarantäne in einer frischen macOS-27-VM installieren, individuell freigeben, lokal und mit HTTPS-Profil verwenden. Kein Developer-Account auf Testsystem nötig.
- Update von einem vorherigen Testbuild mit Workspace, aktivem Block und Backups durchführen. Recovery und Rückkehr zum vorherigen Build nur bei nachgewiesener Schemakompatibilität; kein blindes Daten-Downgrade.
- Entfernen dokumentieren und testen: eigene Einträge bewusst deaktivieren, Login-Start deaktivieren, App entfernen; App-Daten und root-eigene Backupdaten nur über eine enge freigegebene Cleanup-Operation entfernen. Kein allgemeines privilegiertes `rm` und keine fremden Hosts-Zeilen löschen. Bei Entfernung nur per Finder bleiben Hosts-Änderungen bestehen; das Handbuch sagt dies deutlich.
- `docs/verification/release-1.0.md` mit Ergebnissen aller Gates, unterstützten OS-/Importversionen, Paketdigest, Limitierungen und Prüfumgebung abschließen.

**Gate 9 / Definition of Done:** alle Gates bestanden und belegt; Clean Build, Format, Core-/Integration-/UI-Tests und reale VM-Durchläufe erfolgreich; Installieren, Benutzen, Update, Wiederherstellen und Entfernen mit dem tatsächlichen Artefakt nachgewiesen. Erst dann „produktionsreif“ melden. Veröffentlichung erfolgt nur, wenn sie im späteren Arbeitsauftrag beauftragt ist; ein lokales Release-Artefakt kann vorher vollständig geprüft werden.

## Übergreifende Prüfbefehle

Das gemeinsame Scheme `MacHosts` und der UI-Testplan sind vorhanden. Die geprüften Befehle mit Cache- und Ausgabepfaden stehen in [ENTWICKLUNG.md](ENTWICKLUNG.md), Ergebnisse in [Phase 1](verification/phase-1.md). Kurzformen außerhalb der Coding-Sandbox:

```sh
swift test --package-path Packages/MacHostsKit
xcrun swift-format lint --strict --recursive MacHosts MacHostsApply Packages/MacHostsKit
xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -configuration Release -destination 'platform=macOS,arch=arm64' build
xcodebuild -project MacHosts.xcodeproj -scheme MacHosts -destination 'platform=macOS,arch=arm64' test
```

Tests standardmäßig ohne privilegierte Operationen. VM-Systemtests sind eine gesonderte, absichtlich gestartete Suite mit Restore-Prüfung; sie werden nicht an `swift test` angehängt. Nach bestandenen relevanten Checks nur bei neuen Änderungen, Fehlschlägen oder offenen Risiken weitere Wiederholungen ansetzen.
