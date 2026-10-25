# ADR 0002 – Gate 0 zurückstellen und unabhängig weiterentwickeln

Datum: 25. Oktober 2026. **Status: angenommen auf ausdrücklichen Nutzerauftrag.**

## Entscheidung

Gate 0 wird zurückgestellt, nicht als bestanden behandelt. Der Nutzer möchte Projektaufbau und unabhängige Produktentwicklung fortsetzen und den privilegierten Schreibweg später lösen. Die bisherige pauschale Sperre aller Folgephasen entfällt.

Phasen 1–3 dürfen vollständig umgesetzt werden. Phasen 4–7 dürfen mit unprivilegierten, privaten Fixtures und einem ausdrücklich nicht verfügbaren Systemwriter vorbereitet und entwickelt werden; ihre fachlichen Abhängigkeiten bleiben bestehen. UI, Menüleiste, Import und Remote dürfen dabei keinen Systemwrite als erfolgreich darstellen. Eine Simulation darf ausschließlich als solche erkennbar in Tests oder einem ausdrücklich gewählten Demomodus laufen, niemals als stiller Ersatz für die echte Übernahme.

Gate 0 bleibt Voraussetzung für Freischaltung des produktiven privilegierten Writers und den echten Integrationsabschluss von Phase 4. Gates 8 und 9 einschließlich Produktions- und Releasefreigabe setzen weiterhin sämtliche echten Integrationsnachweise voraus. Teilabschlüsse werden getrennt von bestandenen Gesamtgates dokumentiert.

## Konsequenzen

Der Autorisierungsadapter bleibt bis zum Nachweis nicht verfügbar. Das eingebettete Tool führt keine Systemoperationen aus und lehnt Root-Start ab. Parser, Workspace und UI bleiben unabhängig von der späteren Autorisierung. Ein Architekturwechsel wegen eines negativen Phase-0-Nachweises wird weiterhin über ADR dokumentiert.

Die lokale Hosts-Datei des Arbeitsrechners bleibt als Schreibziel einschließlich Metadaten ausgeschlossen. Echte privilegierte Tests bleiben auf eine bestätigte Wegwerf-VM begrenzt. Kein persistenter Root-Helper, keine aufgeweichten Dateirechte und kein vorgetäuschter Erfolgsstatus.

## Ablösung

Diese Entscheidung ersetzt die zeitliche Gate-0-Sperre in den bisherigen Planungsdokumenten. Die Sicherheits- und Datenintegritätsverträge aus ADR 0001 und Architektur bleiben bestehen. Die VM-Tests bleiben vertagt, bis der Nutzer ihre Durchführung beauftragt und eine geeignete VM bestätigt ist.
