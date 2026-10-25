# MacHosts – Coding-Anweisungen für Codex

Dies ist der Arbeitsvertrag für die spätere Umsetzung. Zuerst [Projektskizze](PROJEKTSKIZZE.md), [Architektur](ARCHITEKTUR.md) und [Phasenplan](UMSETZUNGSPLAN.md) lesen. Quellen und ursprüngliche Bewertung stehen in [RECHERCHE.md](RECHERCHE.md). Diese Dateien beschreiben Zielverhalten; vor jeder Aussage über vorhandene Funktionen den tatsächlichen Code prüfen.

## Zurückgestelltes Gate 0

Auf ausdrücklichen Nutzerauftrag gilt [ADR 0002](decisions/0002-deferred-gate-0.md): Gate 0 blockiert unabhängige Folgeentwicklung nicht mehr. Phasen 1–3 sind freigegeben; weitere lokale Abläufe dürfen mit privaten Fixtures und nicht verfügbarem Systemwriter entwickelt werden. Produktiver privilegierter Betrieb und dessen Integrations-/Releasefreigabe benötigen weiterhin Gate 0. Diese Regel ersetzt entgegenstehende Reihenfolgepflichten und die frühere Phase-0-Begrenzung in den untenstehenden Promptvorlagen. Eine allgemeine Fortsetzung arbeitet am nächsten unabhängigen Block weiter.

## Verbindliche Entscheidungen

macOS 27.0+, arm64, Swift, SwiftUI, Deutsch/Englisch, MIT. Vertrieb ohne Apple-Account/Developer ID/Notarisierung, mit technisch notwendiger Ad-hoc-Signatur. Systemautorisierung bei bewusster Übernahme, kein persistenter Root-Dienst in V1. Änderungen bleiben bis zum manuellen Ausschalten bestehen. V1 umfasst lokale Profile, Eintragsschalter, Ordner, Menüleiste, Editor, Preview, Konflikte, Backup/Recovery, Remote und ausgewiesenen SwitchHosts-Import. Kein Auto-Apply für Downloads.

Die Dokumentationserstellung beauftragt noch keine Umsetzung oder Veröffentlichung. Sobald der Nutzer eine Phase oder den gesamten Umsetzungsplan zur Abarbeitung beauftragt, deren notwendige reversible Implementierungsarbeiten ohne wiederholte Routinefreigaben ausführen. Nicht bereits beantwortete Produktfragen erneut stellen.

## Umfang, Tempo und Token-Effizienz

Die am 25. Oktober 2026 bestätigte Arbeitspräferenz gilt für weitere Coding-Runs: möglichst viele zusammenhängende Schritte und mehrere ausführbare Phasen in einem Run abschließen. Ein allgemeines „continue coding“ setzt die Umsetzung innerhalb des vereinbarten Projektumfangs fort. Nicht nach einer kleinen Einzelkorrektur auf einen weiteren Prompt warten. Explizit beschränkte Aufträge und erforderliche Gates bleiben verbindlich; diese Präferenz erklärt kein offenes Gate für bestanden.

Vor dem Editieren einen größeren fachlich geschlossenen Arbeitsblock anhand von Abhängigkeiten und tatsächlichem Status auswählen. Zugehörige Implementierung, Fehlerbehandlung und aussagekräftige Tests gemeinsam vorbereiten. Tests erst nach größeren Abschlüssen ausführen und mit Build-/Formatprüfungen sinnvoll bündeln. Ein notwendiges Gate wird vor abhängigen Arbeiten geprüft, auch wenn der Run danach weitergeht. Bei einem Fehler die betroffene Ursache beheben und die relevanten Checks erneut ausführen; keine unveränderten erfolgreichen Suiten ohne Anlass wiederholen.

Für effiziente Durchführung:

- Mit `rg` Dateien und Symbole lokalisieren; gezielte Bereiche statt großer Gesamtausgaben lesen. Unabhängige Such-/Leseabfragen bündeln. Unveränderte Vorgaben innerhalb desselben Kontexts nicht mehrfach vollständig laden.
- Vorhandene Muster und gemeinsame Fachlogik nutzen. Keine unnötigen Bibliotheken, Generatoren, Architekturwechsel, spekulativen Features oder sachfremden Aufräumarbeiten.
- Tests auf beobachtbares Verhalten, Datenintegrität und Fehlergrenzen konzentrieren. Parametrisierte Fälle für gemeinsame Verträge verwenden; keine bedeutungslosen Testduplikate oder Tests für rein kosmetische Änderungen.
- Bestehende Build-Caches und inkrementelle Builds verwenden; Clean Builds nur bei konkretem Bedarf oder gefordertem Nachweis. Lange Toolausgaben lokal protokollieren und nur relevante Fehler und kompakte Ergebnisse lesen/berichten.
- Dokumentationsänderungen direkt auf Konsistenz und Verweise prüfen; dafür keine Swift-Builds oder Laufzeittests starten. Status und Nachweise nach einem größeren Abschluss gesammelt aktualisieren statt jeden Zwischenschritt zu protokollieren.
- Bei einer echten Blockade verbleibende unabhängige Aufgaben bearbeiten. Lässt sich kein sinnvoller erlaubter Block mehr abschließen, die konkrete Blockade und den nötigen nächsten Schritt nennen. Keine Serie kleiner Prototypkorrekturen erzeugen, nur um Aktivität vorzuweisen.
- Routineentscheidungen ohne Rückfragen treffen. Kurze Updates zu Ergebnissen und Richtungswechseln geben; Abschlussbericht auf Änderungen, tatsächlich ausgeführte Checks und verbleibende Grenzen beschränken. Keine Subagents ohne ausdrücklichen Auftrag.

## Code und Struktur

1. Eigene Produktlogik ausschließlich Swift. Systemframeworks direkt verwenden. AppKit ist für den Editor zulässig und bleibt hinter einer kleinen SwiftUI-Brücke. Keine WebView, HTML-/JS-Oberfläche oder andere Sprachlaufzeit.
2. Swift-6-Sprachmodus mit vollständiger Concurrency-Prüfung. UI explizit auf dem Main Actor; Core-Logik unabhängig davon. Compiler-/SDK-Version im Entwicklungsleitfaden festhalten. Keine erfundenen Buildsettings oder Versionsschalter.
3. `struct`/`enum` und `Sendable` für Domänenwerte, Actors für geteilten veränderlichen Zustand, `@Observable` für UI-Modelle. Nach `await` Gültigkeit von Revision und Transaktion prüfen. Kein `DispatchSemaphore.wait()` zum synchronen Überbrücken von async.
4. Kleine verständliche Typen und Methoden. Protokolle nur an realen Grenzen wie Store, Autorisierung, Systemdatei oder Netzwerk. Kein Protokoll für jeden Typ, kein generisches Repository-/Eventbus-/Pluginframework.
5. Keine `try!`, ungeprüften Force-Unwraps oder stillen `try?` an I/O- und Sicherheitsgrenzen. Fehler typisieren, intern Kontext erhalten und dem Nutzer verständlich übersetzen. Keine vollständigen Inhalte in Fehlermeldungslogs.
6. Keine pauschalen `@unchecked Sendable`, `nonisolated(unsafe)` oder ausgeschalteten Warnungen. Eng begrenzte Ausnahme nur mit schriftlicher Begründung und nachgewiesener Synchronisation. Unsafe/POSIX-Code auf die nötige Dateigrenze beschränken und dort prüfen.
7. Swift API Design Guidelines, `swift-format`-Konfiguration und englische Identifier verwenden. Kommentare erklären Verträge und nicht offensichtliche Gründe; offensichtlichen Code nicht nacherzählen. Öffentliche Schnittstellen und gefährliche Dateitransaktionen dokumentieren.
8. Frameworks und Libraries nur bei tatsächlichem Nutzen hinzufügen. Start ohne externe Laufzeitabhängigkeiten. Keine unnötigen Buildgeneratoren, SwiftData-Schicht oder State-Management-Bibliothek.
9. Eine Fachlogik für Fenster, Menüleiste, Import und Tool. Parser/Composer nicht für die Vorschau in einer View nachbauen. Vorschau und privilegierter Write müssen denselben eingefrorenen Plan und dieselben Regeln prüfen.

## Sicherheit und Datenintegrität

- App nie als Root starten. Keine Kennwortfelder und kein Kennwortcache in der App. Keine Erweiterung von Hosts-Dateirechten, keine `sudoers`-Sonderregeln, kein veraltetes `AuthorizationExecuteWithPrivileges`.
- Tool nur mit dem in Phase 0 belegten Vertrauens- und Autorisierungsweg ausführen. Ad-hoc-Signatur oder gleicher Bundle-Identifier alleine beweisen keine Identität. Keine ungeprüft nutzerbeschreibbare Binary als Root starten.
- Keine benutzerdefinierten Shellbefehle. Produktdaten dürfen weder in Shell- noch AppleScript-Syntax interpoliert werden. Eine feste OS-Brücke darf nur eng validierte Argumente übertragen; jedes Escaping separat und mit bösartigen Eingaben prüfen.
- Privilegierte Requests eng versionieren und begrenzen; fester Zielpfad, keine beliebigen Lese-/Schreib-/Cleanup-Pfade. Alle Validierungen im Tool wiederholen. Freie Pfadwahl auch nicht als versteckten Production-Testmodus zulassen.
- Vor Systemwrite Originalbytes/Metadaten sichern und Journal dauerhaft schreiben. Kein Backup, kein Write. Vorhandene Symlinks/Hardlinks, unerwartete Dateitypen und unsichere Verzeichnisse abweisen.
- Fremde Bytes außerhalb des eigenen Blocks erhalten. Kaputte Marker blockieren, fremde Verwaltung nicht übernehmen. Rücksicherung nur auf Basis des frisch geprüften Iststands; kein automatisches Überschreiben nach Crash.
- Gewünschten und angewendeten Snapshot trennen. Erfolg nur nach Readback/Receipt, Cache-Status separat. Abbruch/Timeout kann bei begonnenem Commit „Ausgang unklar“ bedeuten.
- Kein automatischer Download-Apply, keine TLS-Ausnahme, keine Cloud-/Telemetrypflicht. Remote-/Importgrößen während des Lesens begrenzen. Alte oder fehlgeschlagene Antworten überschreiben keinen gültigen Stand.
- Die lokale Hosts-Datei des Arbeitsrechners darf in keinem Coding-Run verändert werden: weder durch Tests noch durch App-Demos, manuelle Probeaufrufe, Build-/Hilfsskripte oder Recovery. Das umfasst `/etc/hosts`, `/private/etc/hosts`, Alias-/Linkpfade sowie Rechte, Eigentümer und Metadaten. Auch ein anschließendes Zurücksetzen legitimiert keinen lokalen Testwrite. Normale Schreibtests verwenden ausschließlich private Fixtures mit injizierten Dateisystem-/Autorisierungsadaptern. Alle echten privilegierten Systemwrite-Tests ausschließlich in einer bestätigten Wegwerf-VM; deren eigene Hosts-Datei ist das bewusst isolierte Testziel.

## UI-Regeln

Native Controls, `NavigationSplitView`, `Settings`, `Commands`, `MenuBarExtra`, SF Symbols und String Catalogs verwenden. Systemdarstellung ohne eigene Glasoptik auf dem Editor. Tastaturfokus, VoiceOver und Undo von Anfang an beachten. Technische Implementierungsdetails gehören nur dann in die Produktoberfläche, wenn sie eine Nutzerentscheidung unterstützen.

Hauptfenster-Schalter bearbeiten den gewünschten Zustand. Menü-Schnellaktion zeigt vor Übernahme alle betroffenen Änderungen. Ein aktives Profil mit neuem Entwurf darf nicht als bereits aktualisierte Systemkonfiguration erscheinen. Systemdatei als Istzustand ist schreibgeschützt; Änderungen erfolgen über Profile und den gemeinsamen Apply-Dienst.

## Arbeitsablauf je Phase

1. Aktuellen Status und Code prüfen. Erste offene Phase auswählen, Abhängigkeiten und unverhandelbare Gates benennen.
2. Einen größeren zusammenhängenden Ergebnisblock implementieren; verwandte Schritte bündeln. Keine spätere abhängige Phase vorziehen, um ein ungelöstes Gate zu verdecken.
3. Erst am größeren fachlichen Abschluss relevante Tests und statische Checks gebündelt ausführen, spätestens vor dem erforderlichen Gate. Tests müssen Verhalten/Verträge prüfen, keine internen Implementierungsdetails spiegeln. Kritische Transaktionsfehler mittels gezielter Fehlerinjektion prüfen.
4. Eigenen Diff auf Fehler, Rechteausweitung, unnötige Abhängigkeiten, Log-Geheimnisse, vorgetäuschte Erfolge und unvollständige Recovery prüfen.
5. `docs/verification/phase-N.md` und Status im Plan aktualisieren. Exakte bestandene und nicht ausgeführte Checks unterscheiden. Nachweise nicht durch Behauptungen ersetzen.
6. Innerhalb des beauftragten Umfangs nach bestandenem Gate im selben Run zur nächsten Phase wechseln. Bei allgemeiner Fortsetzungsanweisung möglichst mehrere ausführbare Phasen/Schritte abschließen. Erst am Ende knapp berichten: was funktioniert, wie geprüft, welche Grenzen bleiben und welche Phase folgt.

Keine Subagents ohne ausdrücklichen Auftrag oder anderweitig geltende Anweisung. Keine Veröffentlichung, PR-Erstellung oder Netzwerkkommunikation als bloße Nebenwirkung der lokalen Implementierung. Keine geplante Funktion als geliefert bezeichnen.

## Startprompt: erste Implementierungsphase

```text
Implementiere MacHosts nach docs/PROJEKTSKIZZE.md, docs/ARCHITEKTUR.md,
docs/UMSETZUNGSPLAN.md und docs/CODEX-ANWEISUNGEN.md.
Bearbeite zunächst ausschließlich Phase 0 vollständig.
Beachte die bereits bestätigten Produktentscheidungen und erfrage sie nicht erneut.
Weise den accountlosen privilegierten Schreibweg mit engem Swift-Tool nach;
ein Admin-Dialog allein genügt nicht. Prüfe Toolherkunft, Requestintegrität,
Abbruch und Recovery. Verwende echte Systemwrites ausschließlich in einer
wegwerfbaren macOS-27-VM, niemals an der Hosts-Datei des Arbeitsrechners.
Fehlt die VM, erledige unabhängige Prototyp-/Testarbeiten und dokumentiere
die ausstehenden Nachweise; markiere Gate 0 nicht als bestanden.
Lege ADR 0001 und den Phasenbericht an. Falls ein sicherer Weg unter den
bestätigten Bedingungen nicht nachweisbar ist, liefere konkrete Alternativen,
statt die Sicherheitsverträge aufzuweichen. Gate 0 darf gemäß ADR 0002 zurückgestellt werden; setze unabhängige
Folgearbeiten mit nicht verfügbarem Systemwriter fort.
```

## Folgeprompt: weitere Phase

```text
Setze möglichst viele zusammenhängende offene Schritte und Phasen des
MacHosts-Umsetzungsplans in diesem Coding-Run vollständig um.
Lies zuerst den aktuellen Status, die zugehörigen Nachweise und die
Coding-/Architekturverträge. Prüfe, dass alle benötigten Gates bestanden sind.
Implementiere größere fachliche Blöcke und bündele Tests erst an deren
Abschlüssen; prüfe erforderliche Gates vor abhängigen Phasen.
Verändere niemals die lokale Hosts-Datei des Arbeitsrechners.
Verifiziere und dokumentiere das Ergebnis. Aktualisiere Status
und Phasenbericht; melde verbleibende Risiken und nicht ausgeführte Checks.
Halte die bereits bestätigten Produktentscheidungen ein.
```
