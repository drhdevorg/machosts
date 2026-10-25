# ADR 0003 – Verwaiste Apply-Absichten dauerhaft stilllegen

Datum: 25. Oktober 2026. Status: interner Vertrag implementiert und an privaten Fixtures geprüft; keine Freigabe eines privilegierten Protokolls. Gate 0 und Gate 4 bleiben offen.

## Problem

Eine gespeicherte App-Absicht kann nach Prozessende ohne Systemjournal zurückbleiben. Der aktuelle Dateidigest beweist weder einen früheren Commit noch dessen Ausbleiben. Zudem könnte ein verzögerter Worker erst nach einem Recoveryversuch seinen Prozesslock erwerben. Ein fehlendes Journal bei momentan freiem Lock reicht deshalb nicht, um die Absicht gefahrlos zu löschen.

## Entscheidung

Ein ausdrücklich angeforderter interner Vorgang `retireOrphan` legt eine dauerhafte Stilllegung für die konkrete Transaktion an. `ApplyRetirement` bindet Version 1, Transaktions-ID, Vorher-/Nachher-Digest und Workspace-Digest. Er enthält keine Profiltexte, Dateipfade, Befehle oder Autorisierungsdaten. Die Stilllegung ist kein Receipt und kein Nachweis, dass historisch niemals ein Write stattgefunden hat. Der neue Ausgang heißt ausdrücklich `retired`, getrennt von `notCommitted`.

1. Die App muss die noch offene Transaktions-ID benennen und die gemeinsame Recovery-Sperre halten. Neuere Entwurfsänderungen bleiben erlaubt. Keine automatische Stilllegung durch Dateibeobachtung oder normalen Recoveryabgleich.
2. Der Systemadapter muss denselben exklusiven Prozesslock wie jeder Commit halten. Laufende Worker verhindern den Vorgang. Auch verzögerte Worker müssen nach Lockübernahme die Stilllegungen prüfen, bevor sie Backup, Journal oder Zielbytes schreiben.
3. Stilllegung ist nur ohne Journal der betroffenen ID, ohne andere vorbereitete Transaktion und bei frisch gelesenen Vorher-Bytes erlaubt. Vorhandene Journale nutzen den bestehenden Recoverypfad. Nachher-Bytes, andere Bytes, Lesefehler und beschädigte Nachweise bleiben gesperrt.
4. Der Adapter speichert die Stilllegung dauerhaft, liest sie zurück, synchronisiert Datei und Verzeichnis und prüft die unveränderte Zielidentität samt Bytes/Metadaten erneut. Ein erneuter Aufruf mit identischer Bindung ist idempotent; andere Bindungen derselben ID sind Fehler. Widersprüche zwischen Journal und Stilllegung blockieren.
5. Jeder Commit weist eine stillgelegte ID mit `replay` ab, unabhängig von deren angefragten Digests oder Operationen. Die Stilllegung wird nach Auflösung der App-Absicht nicht gelöscht. Ohne nachgewiesenen Ausschluss aller alten Requests darf Retention diese Einträge nicht entfernen.
6. Beim späteren Recovery synchronisiert der Adapter auch eine bereits sichtbare Stilllegung nochmals. Ein früherer Prozess könnte nach Rename und vor Verzeichnis-Sync gestorben sein. Ein fehlgeschlagener Sync erlaubt keine terminale Evidenz. Tests mit Prozessende sind kein Nachweis für Stromausfallsicherheit des Dateisystems.
7. Die App validiert die unabhängige Stilllegung vollständig gegen ihre Absicht und liest die Systembytes nach der Evidenzprüfung erneut. Nur bei Vorher-Digest löst sie die Absicht ohne neuen Receipt auf. Älterer angewendeter Snapshot und neuerer Entwurf bleiben erhalten; das Ergebnis lautet `unconfirmed`. Ein späterer normaler Abgleich kann den älteren Receipt gesondert mit der aktuellen Datei vergleichen.

Nach gespeichertem Sperreintrag können Lesefehler, Cancellation, externe Änderungen oder App-Save-Fehler die Auflösung verhindern. Die Absicht bleibt dann erhalten; die dauerhaft gesperrte Transaktion darf trotzdem nie erneut committen. Der nächste Neustart kann den Sperreintrag unabhängig wiederfinden. Auch ein früherer tatsächlicher Commit mit verlorenem Journal und inzwischen wiederhergestellten Vorher-Bytes erzeugt auf diesem Weg keinen erfundenen Erfolgs- oder Nicht-Commit-Nachweis.

## Abgrenzung und Folgen

Der Vertrag erweitert die bisherigen zulässigen terminalen Nachweise. Die Architekturregel „passende Bytes allein reichen nicht“ bleibt bestehen. Stilllegung ändert ausschließlich unabhängige Transaktionsnachweise und App-Daten, niemals die Zielbytes. Sie ersetzt keine kontrollierte Rücksicherung und ist bei Nachher-/Fremdbytes kein Ausweg.

Die Methode des Koordinators ist intern. Nur Testadapter implementieren sie; die Standardimplementierung wirft `integrationUnavailable`. Es gibt keine UI-Aktion und keinen CLI-Schalter zum Verwerfen von Absichten. Die Produktionsoberfläche bleibt bei verwaisten Absichten gesperrt. Workspace-Schema 2 bleibt unverändert.

Vor produktiver Nutzung sind sichere Autorisierung, vertrauenswürdiger Speicher/Transport, begrenzte eindeutige Dekodierung, vollständige Metadatenprüfung und der Gate-0-Herkunftsnachweis erforderlich. Alle beteiligten Worker einschließlich alter/verzögerter Prozesse müssen die Sperreinträge beachten; gemischte Protokollgenerationen sind ohne gesonderten Nachweis nicht zugelassen. App- und Systemdaten müssen bei Backup-/Downgrade-/Cleanupvorgängen gemeinsam bewertet werden. Das Löschen oder Zurücksetzen der unabhängigen Stilllegungen würde den Replay-Schutz aufheben. Es gibt weiterhin kein atomisches Compare-and-Swap gegenüber nicht kooperierenden Fremdschreibern.

Prüfergebnisse und Grenzen: [Phase 4](../verification/phase-4.md).
