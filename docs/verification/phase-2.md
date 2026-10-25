# Phase 2 – Parser und reine Fachlogik

Stand: 25. Oktober 2026. **Implementiert und lokal verifiziert; Gate 2 bestanden.** Die formalen Clean-Checkout-/CI-Punkte aus Phase 1 bleiben offen. Die unabhängige Entwicklung ist gemäß ADR 0002 erlaubt; Gate 0 bleibt zurückgestellt.

## Ergebnis und Formatentscheidungen

`HostsCore` enthält einen UTF-8-Parser mit originalen Bytebereichen und LF-/CRLF-/CR-Zeilenenden, IP-Normalisierung über Systemfunktionen, ASCII-Hostnameprüfung, Profile/Ordner/Papierkorb und revisions-/digestgebundene Eintragsschalter. Unicode bleibt in Kommentaren erhalten. Nicht unterstützte Kodierung/BOM, Steuerzeichen, ungültige Adressen, Zonenangaben, führende IPv4-Nullen und reservierte Marker werden diagnostiziert. Ein einzelner finaler DNS-Punkt wird zur Konfliktprüfung entfernt; Labels sind 1–63 Bytes, der Name ohne finalen Punkt höchstens 253 Bytes. Lokale Einzelnamen und ASCII-Punycode sind erlaubt.

Die Komposition folgt Profil- und Quellreihenfolge, dedupliziert kanonische Adresse/Domain und bewahrt die Herkunft aller beteiligten Einträge. Mehrere Adressen derselben Familie blockieren auch gegenüber fremden Systemeinträgen. IPv4 und IPv6 derselben Domain sind zulässig. Deaktivierte Profile werden nicht komponiert; ungültige Zeilen in aktiven Profilen blockieren. Remote-Profile sind für Zeilenschalter schreibgeschützt.

`ApplyPlan` friert Workspace-/Quelldigests, Systemdigest, aktive IDs, Vorher-/Nachherbytes, Blockoperation und hinzugefügte/entfernte Zuordnungen ein. Workspace-Digest erkennt auch Änderungen ohne versehentlich ausgelassene Revisionserhöhung. Ein erwarteter Managed-Block-Digest ermöglicht später dem Coordinator die Abweisung externer Änderungen. Es gibt keine Dateizugriffe und keinen Writer in dieser Logik.

Präfix/Suffix bleiben bytegleich. Marker zählen ausschließlich als ganze Zeile; doppelte, umgekehrte, verschachtelte oder fehlende Marker blockieren. Eingebettete/andere MacHosts-Marker werden abgelehnt; SwitchHosts-Kommentare bleiben fremd. Nur ein digestgebundener `ManagedSeparatorEvidence` erlaubt die Entfernung eines beim Anhängen eingefügten LF. Ohne diesen Nachweis bleibt der LF erhalten. Die spätere Persistenz muss den Nachweis dem bestätigten Systemstand zuordnen. Ein vorhandenes Blockende behält seinen Zeilentrenner; neu erzeugte innere Blockzeilen nutzen LF.

## Tatsächliche Verifikation

Apple Silicon, Xcode 27.1 / Swift 6.4, macOS-SDK 27.0. Befehle/Cachepfade wie in `docs/ENTWICKLUNG.md`.

- `swift test`: bestanden; 12 Core-Testfunktionen plus Writer-Sperrtest, parametrisierte Format-/Fehlerfälle und 100 deterministisch generierte Fremdbereich-Fixtures; `/tmp/machosts-phase2-swift-test.log`.
- Strikte rekursive Formatprüfung: bestanden; `/tmp/machosts-phase2-format.log`.
- Inkrementeller Xcode-Release-Build von App und Tool: bestanden; `/tmp/machosts-phase2-build.log`. Erforderte erneut Cachezugriff außerhalb der Coding-Sandbox.
- Geprüft: zeilentreuer Roundtrip, fehlender finaler Zeilenumbruch, BOM/ungültiges UTF-8, Limits, Markerfehler, Aliaslisten, Normalisierung, Umschalten mit veraltetem Digest, Remote-Schreibsperre, deterministische Komposition/No-op, Fremdkonflikte, vollständige Herkunft, Preview-Differenzen, externer Blockdigest und bytegenaues Entfernen.

Im ersten Prüflauf gefundene Abweichungen des Darwin-Parsers (führende Nullen, Zonenangaben) und BOM-Decoders sind explizit abgefangen; der abschließende Lauf bestand. Zwei reine Swift-Compilerprobleme (throwing Kurzschlussausdruck, komplexer Testmakroausdruck) wurden ebenfalls behoben.

Keine UI-Funktionalität oder Performancebudgets abgenommen. Kein Systemhosts-Zugriff, keine Autorisierung und keine privilegierte Integration. Nächster unabhängiger Block: Phase 3, persistente Workspace-Snapshots und unprivilegierte Recovery.
