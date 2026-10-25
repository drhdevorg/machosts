# MacHosts – Projektskizze

Stand: 25. Oktober 2026. Status: im Dialog bestätigte Produktrichtung; technische Nachweise stehen aus. Dieses Dokument beschreibt das Zielprodukt, keine bereits implementierten Funktionen.

## Produkt und Nutzen

MacHosts verwaltet Hosts-Profile für Entwickler auf dem Mac. Ein Profil kann beispielsweise `203.0.113.42 shop.example` enthalten, um die Produktionsdomain lokal auf die IP eines Stagingservers zu legen. Die App zeigt vor der Übernahme die resultierende Änderung und erhält alle fremden Einträge. Ausschalten entfernt ausschließlich die von MacHosts verwalteten Zuordnungen.

Die Hosts-Datei gilt für den gesamten Mac, nicht nur für den angemeldeten Nutzer. MacHosts macht diesen Umfang sichtbar. Der Stagingserver muss die Domain inklusive TLS-Zertifikat bedienen; Port-, URL- und Zertifikatsumleitungen sind nicht Teil der App.

## Bestätigte Entscheidungen

| Thema | Entscheidung |
| --- | --- |
| Name | MacHosts |
| Plattform | macOS 27.0+, ausschließlich arm64 / Apple Silicon |
| Implementierung | eigene Laufzeitlogik vollständig Swift; SwiftUI, gezieltes AppKit für den Editor |
| Toolchain | vorhandenes Xcode 27.1 / Swift 6.4 als Ausgangspunkt, stabile Version im Bootstrap fixieren |
| Distribution | außerhalb des App Store, ohne Apple-Developer-Account, Developer ID oder Notarisierung |
| Technische Signatur | Ad-hoc, kein Herausgeberzertifikat; Gatekeeper-Ausnahme beim Erststart akzeptiert |
| Autorisierung | ausdrückliche Übernahme mit macOS-Systemautorisierung; kein dauerhafter Root-Dienst in V1 |
| Temporär | bis zum manuellen Ausschalten; überlebt App-Ende und Neustart |
| Bedienung | natives Hauptfenster mit Sidebar und Editor, zusätzlich Menüleiste |
| Sprachen | Deutsch und Englisch, Code und technische Bezeichner Englisch |
| Lizenz | MIT, unabhängige Implementierung |
| V1-Umfang | lokale Basis plus Remote-Profile und SwitchHosts-Import |

Eine kleine feste OS-Autorisierungsbrücke darf einen Swift-Prozess starten; Parser, Dateitransaktion und alle Produktregeln bleiben Swift. Ein solcher Integrationsweg ist eine Umsetzungshypothese, noch kein freigegebener technischer Nachweis. Kein AppleScript als Fachlogik und keine neue andere Laufzeitabhängigkeit.

## Arbeitsabläufe

### Erststart

1. App nach Applications kopieren und gegebenenfalls die individuelle macOS-Erststartfreigabe durchführen.
2. Kurze Erklärung: Änderungen gelten systemweit, bleiben nach Beenden aktiv und benötigen administrative Freigabe.
3. Aktuelle Hosts-Datei nur lesen; kein Schreibzugriff und keine Admin-Abfrage beim Start.
4. Ein Beispielprofil über eine bewusste Aktion erstellen; nie automatisch aktivieren. Bestehende fremde Hosts-Verwaltung anzeigen.

### Profil bearbeiten und übernehmen

1. Profil erstellen oder wählen, Einträge schreiben, einzelne Einträge oder das ganze Profil aktivieren.
2. Änderungen lokal automatisch speichern; klarer Hinweis „Noch nicht angewendet“.
3. „Übernehmen“ öffnet Diff mit ergänzten/entfernten Zuordnungen, aktiven Profilen und Konflikten.
4. Nach Bestätigung Systemautorisierung aufrufen. Das OS entscheidet, ob ein erneuter Dialog nötig ist; kein Versprechen einer Passwortabfrage bei jeder Aktion.
5. Erst nach erfolgreicher Prüfung der Datei wird der angewendete Stand angezeigt. Abbruch behält den Entwurf und den alten Istzustand.

Die Profil-Aktivierung im Hauptfenster ändert zunächst die gewünschte Konfiguration. Speichern und Anwenden sind sichtbar getrennt. Dies bündelt mehrere Änderungen in einer Übernahme.

### Schnellaktion in der Menüleiste

Menüleiste zeigt angewendete Profile, ausstehende Änderungen und den Systemzustand. „Profil aktivieren und übernehmen“ durchläuft denselben Preview-/Autorisierungsweg wie das Hauptfenster, mit kompakter Vorschau. Bei bereits offenen Entwurfsänderungen wird vor der Übernahme deren gesamter Umfang gezeigt; kein stilles Mitübernehmen und kein stilles Verwerfen. Bei Fehlern bleiben Häkchen für den tatsächlich bestätigten Stand korrekt.

„Alle MacHosts-Einträge deaktivieren“ ist jederzeit erreichbar und entfernt nach Vorschau und Freigabe nur den eigenen Abschnitt. Es ist keine Rücksetzung der gesamten Systemdatei auf eine frühere Kopie.

### Externe Änderung und Recovery

Bei einer Änderung durch Terminal, VPN oder eine andere App zeigt MacHosts „Extern geändert“. Eine neue Vorschau bezieht sich auf den aktuellen Stand. Extern veränderte eigene Blöcke werden nicht still überschrieben. Bei widersprüchlichen Markern oder einem offenen Transaktionsjournal sind weitere Writes bis zur Klärung gesperrt; Lesen und Export bleiben möglich.

### Remote-Profile

HTTPS-URL hinzufügen, Inhalt laden, Herkunft und Änderungen prüfen, anschließend bewusst aktivieren und anwenden. Ein Download verändert niemals automatisch `/etc/hosts`. Letzter gültiger Inhalt bleibt offline verfügbar. Ungültige Downloads ersetzen keinen gültigen Cache.

Manuelle Aktualisierung gehört zu V1. Optional aktivierbare Aktualisierung beim Start und in Intervallen läuft ausschließlich, während die App geöffnet ist, verwendet bedarfsgesteuerte Timer und holt nach Sleep höchstens eine fällige Aktualisierung pro Quelle nach. Kein Hintergrunddienst und kein minütliches Polling aller Quellen.

## Funktionsumfang V1

| Bereich | Verbindlich |
| --- | --- |
| Profile | erstellen, benennen, duplizieren, sortieren, aktivieren, löschen und lokal wiederherstellen |
| Organisation | Ordner mit stabiler Reihenfolge; Ordner selbst steuern keine Aktivierung |
| Einträge | IPv4/IPv6, mehrere Hostnamen pro Zeile, Kommentare, einzelne Zeilen aktivieren/deaktivieren |
| Komposition | mehrere aktive Profile, deterministische Ausgabe, Herkunft pro Eintrag, Konfliktanzeige |
| Editor | Monospace, native Auswahl/Undo, Zeilennummern, Syntaxfarben, Suche/Ersetzen im Profil, profilübergreifende Suche |
| Prüfung | ungültige IP/Hostname, Dubletten, widersprüchliche Domainbelegung, reservierte Marker |
| Systemansicht | gesamte Datei schreibgeschützt, eigener Abschnitt hervorgehoben, externer Änderungsstatus |
| Sicherheit | Vorschau, Systemautorisierung, eng begrenztes Swift-Tool, Backup, Journal, Readback |
| Wiederherstellung | eigene Zuordnungen deaktivieren, Backups anzeigen/exportieren, kontrollierte Rücksicherung |
| Remote | HTTPS, begrenzter Download, Cache, manuell/optional im laufenden Prozess aktualisieren, kein Auto-Apply |
| Austausch | `.hosts` importieren/exportieren, versioniertes MacHosts-JSON, SwitchHosts-Import mit Preview und Bericht |
| Integration | Menüleiste, optionaler Login-Start, Standardmenüs und Tastaturbefehle |
| Qualität | Deutsch/Englisch, Hell/Dunkel, VoiceOver, Tastatur, Systemdarstellung und Fehlermeldungen |

SwitchHosts-Parität ist funktional gezielt, nicht vollständig: unterstützte Exportversionen werden anhand echter Fixtures festgelegt und dokumentiert. Unbekannte Versionen dürfen nicht „best effort“ als erfolgreich importiert werden.

## Bewusst nach V1 verschoben

- HTTP-API, CLI, globale Hotkeys, App Intents und URL-Scheme-Steuerung.
- Post-Apply-Shellkommandos, eigene Proxyverwaltung und unbeaufsichtigtes Remote-Apply.
- Zeitlimits und automatisches Ausschalten beim Beenden/Crash, persistenter privilegierter Helper.
- Gegenseitig ausschließende Profilgruppen und komplexe Referenzgraphen im eigenen Datenmodell.
- Cloud-Sync, Teamkonten, Blocklisten mit Millionen Einträgen und eigene DNS-/Proxy-Technik.
- Automatischer App-Updater; V1 nutzt manuelle Release-Downloads.
- Intel und ältere macOS-Versionen.

## Qualitätsziele

Korrektheit hat Vorrang: kein Verlust fremder Hosts-Daten, kein falscher Erfolgsstatus, kein generischer privilegierter Befehl. Lokale Profile funktionieren vollständig offline und ohne Telemetrie. Keine Drittanbieter-Laufzeitabhängigkeit zum Start; jede spätere Abhängigkeit braucht einen konkreten Nutzen und dokumentierte Lizenz.

Vorläufige Messbudgets für einen Release-Build auf einem dokumentierten Apple-Silicon-Testgerät: Hauptfenster bei 100 Profilen/insgesamt 10.000 Zeilen innerhalb von zwei Sekunden bedienbar, warmes Menü innerhalb von 150 ms, Eingabe und Scrollen ohne wahrnehmbare Hänger, im lokalen Leerlauf keine periodischen Netzwerkzugriffe und im Mittel unter 1 % eines CPU-Kerns über 60 Sekunden. App-Bundle höchstens 40 MiB und RSS bei leerem Editor höchstens 150 MiB sind Untersuchungsziele, keine bereits gemessenen Eigenschaften. Größere Werte müssen analysiert und begründet werden.

## Voraussetzung für Produktionsreife

Produktionsreife wird erst nach bestandenen Phasengates, Tests der privilegierten Abläufe in einer frischen macOS-27-VM, Recovery-Prüfungen, nativer UI-Abnahme und einem Installations-/Update-/Entfernungsdurchlauf mit dem tatsächlichen Download-Artefakt erklärt. Offene Rechte- oder Datenverlustprobleme schließen einen Release aus. Ein Plan allein belegt keine Produktionsreife.

Details: [Architektur](ARCHITEKTUR.md), [Umsetzungsplan](UMSETZUNGSPLAN.md), [Codex-Anweisungen](CODEX-ANWEISUNGEN.md), [Recherche und Quellen](RECHERCHE.md).
