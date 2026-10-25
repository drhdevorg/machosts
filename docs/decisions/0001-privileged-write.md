# ADR 0001 – accountloser privilegierter Schreibweg

Datum: 25. Oktober 2026. **Status: vorgeschlagen, Sicherheits-/VM-Nachweis ausstehend.** Keine Freigabe für einen eigenen Root-Prozess. Produktentscheidungen bleiben unverändert.

## Kontext und Vertrauensgrenze

MacHosts soll ohne Developer ID vertrieben werden. Eine Ad-hoc-Signatur stellt die ausführbare Integrität innerhalb des signierten Standes dar, keine verlässliche Herausgeberidentität über Updates. Der Nutzer vertraut beim Erststart dem heruntergeladenen Paket. Schutz vor einer bereits ausgetauschten gesamten App ist nicht allein durch Selbstprüfung derselben App erreichbar; Download-Verifikation und lokale Systemintegrität bleiben Voraussetzungen.

Davon getrennt muss die App verhindern, dass ein schwächer geschütztes eigenes Tool zwischen Prüfung und privilegierter Ausführung ausgetauscht wird. Pfad, Bundle-ID, bloßes `chmod` durch den normalen Nutzer oder Hashprüfung vor einem erneuten Öffnen reichen dafür nicht. Dass ein OS-Passwortdialog angezeigt wird, belegt den Code-Vertrauenspfad ebenfalls nicht.

## Aktuelle Entscheidung

Den lokalen Prototyp ohne Root-Fähigkeit entwickeln. Ein optionaler VM-Test prüft einen festen OS-Autorisierungsaufruf für Apples `/usr/bin/id -u`. Eigene Dateilogik läuft ausschließlich unprivilegiert an einer privaten Fixture. Weder die App noch das Demo-Tool unterstützen Root-Ausführung.

Der direkte Start eines Swift-Tools aus einem benutzerbeschreibbaren Bundle über `do shell script … with administrator privileges` ist **nicht freigegeben**. Eine funktionierende Shellquotierung löst weder Toolherkunft noch TOCTOU, dynamische Library-Pfade oder Requestintegrität.

## Weiter zu untersuchender Kandidat

Kurzlebiges Tool mit geschütztem, root-eigenem Staging und expliziter Systemautorisierung. Der Bootstrap darf nur vertrauenswürdige Apple-Systemprogramme nutzen, bis die eigene Binary im geschützten Bereich vollständig kopiert und gegen den erwarteten, vertrauenswürdig gebundenen Digest geprüft ist. Keine Ausführung aus Arbeitsverzeichnis, Downloads oder `/tmp`.

Vor Umsetzung/Abnahme zu beweisen:

1. Ursprung des erwarteten Tooldigests im akzeptierten App-Build; Änderungen am Tool dürfen nicht unbemerkt akzeptiert werden. Ganz-App-Kompromittierung als separate Threat-Grenze ehrlich benennen.
2. Staging-Verzeichnis ohne manipulierbare Eltern, Symlinks oder offen bleibende beschreibbare FDs des Angreifers. Gegen Prüfung/Austausch nach der Kopie absichern. Kein blindes rekursives Kopieren und keine Übernahme untrusted Permissions.
3. Nur System-Dylibs zur Laufzeit; keine nutzerbeschreibbaren `@rpath`-/Library-/Konfigurationspfade oder geerbten Loader-Umgebungsvariablen im privilegierten Tool.
4. Request als unveränderliche, eng begrenzte Daten mit Digestbindung und Transaktionsstatus übernehmen. Kein allgemein privilegiertes Lesen/Schreiben eines Benutzerpfads. Keine Daten als Shellsyntax.
5. Bootstrap und Cleanup müssen kleiner und überprüfbarer bleiben als die verworfene persistente Helper-Architektur. Die feste OS-Brücke darf keine Hosts-Fachlogik in Shell/AppleScript enthalten.
6. Erfolgs-/Abbruch-/Timeout-Ausgang und Update des Tooldigests in einer frischen VM testen. Kein unbeaufsichtigtes Root-Programm und kein Security-Downgrade als Fallback.

Dies ist eine prüfbare Hypothese, kein bereits implementierter oder sicher bewiesener Bootstrap. Falls die feste OS-Brücke dabei zu viel Sicherheitslogik in Shell erfordert, passt sie nicht zum vereinbarten Entwurf und wird verworfen.

## Alternativen bei negativem Nachweis

| Alternative | Auswirkung |
| --- | --- |
| Manuell administrativ installierter root-eigener Swift-Writer, unveränderlich mit enger Schnittstelle | accountlos möglich zu untersuchen; mehr Installations-/Updateaufwand, eigene sichere Aufruferautorisierung weiter nötig; kein automatisch akzeptierter Fallback |
| Developer ID und `SMAppService`/XPC mit prüfbarer Signieridentität | konventionellerer Vertrauenspfad, widerspricht dem bestätigten Accountziel und dem Verzicht auf einen persistenten Helper; nur nach neuer Nutzerentscheidung |
| Lokaler Profilmanager mit Export und manueller Systemübernahme | kein eigener Root-Prozess; reduziert die gewünschte integrierte Umschaltung deutlich und bedarf Produktentscheidung |

Veraltetes `AuthorizationExecuteWithPrivileges`, Root-GUI, weitreichende `sudoers`-Regeln oder dauerhafte Hosts-Schreibrechte bleiben ausgeschlossen. Accountloser Vertrieb wird nicht pauschal für unmöglich erklärt; konkret offen ist der Nachweis dieses engen technischen Entwurfs.

## Nachweise und Quellen

- [Lokaler Phase-0-Bericht](../verification/phase-0.md), [Experiment](../../Experiments/AuthorizationProbe/README.md).
- [Apple TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html): archivierte Beschreibung von OS-Autorisierung und Quotierung; kein aktueller Runtime-Nachweis.
- [Apple DTS zu SMAppService](https://developer.apple.com/forums/thread/802443): dokumentierter Dienstaufbau mit Signierteam; keine Garantie für den accountlosen Kandidaten.
- [Apple: AuthorizationExecuteWithPrivileges](https://developer.apple.com/documentation/security/authorizationexecutewithprivileges): verworfener veralteter API-Pfad.

Quellen am 25. Oktober 2026 erneut aufgerufen. Nur tatsächlich ausgeführte lokale Checks gelten als bestanden. Ein später akzeptiertes ADR muss den konkreten Bootstrap, dessen Testartefakte und verbleibende Threat-Grenzen enthalten.
