# MacHosts

Eine kleine native macOS-App zum Verwalten und gezielten Aktivieren von Hosts-Einträgen für die lokale Entwicklung. Eigene Implementierung in Swift mit SwiftUI; macOS 27 und Apple Silicon.

**Projektstatus: Phasen 1–3 lokal geprüft, Phase 4 teilweise implementiert; Gates 0 und 4 offen.** Die native Projektbasis liegt in `MacHosts.xcodeproj`, die Swift-Module in `Packages/MacHostsKit`. Die Startansicht ist deutsch/englisch lokalisiert. Core und Services bieten Parser, Profile, Konfliktprüfung, unveränderliche Vorschau, atomaren Workspace-Speicher, Autosave und lokale Recovery. Hinzu kommen Apply-Koordination, persistente App-Absicht, Schema-2-Migration und Receipt-/Readback-Abgleich mit Testadaptern; der interne Transaktionskern ist einschließlich Prozessneustarts an privaten Dateifixtures geprüft. Ein unprivilegierter Beobachtungsdienst erkennt externe Änderungen einschließlich atomaren Dateiersatzes; seine App-Anbindung mit Receipt-/Intentabgleich ist implementiert und gebaut, die native UI-/Wake-Abnahme bleibt offen. Die Recovery diagnostiziert fehlende Journale, aktive Worker und unklare Ausgänge getrennt und erhält verwaiste Absichten. Die produktive Systemdateitransaktion bleibt offen. Diese Dienste sind noch nicht in eine Profiloberfläche eingebunden; der Systemwriter bleibt nicht verfügbar. Unabhängige Entwicklung läuft gemäß [ADR 0002](docs/decisions/0002-deferred-gate-0.md) weiter, während sichere Autorisierung und VM-Nachweise später folgen.

Der frühere [Phase-0-Prototyp](Experiments/AuthorizationProbe/README.md) bleibt separat erhalten. Seine vorhandenen App-/ZIP-Artefakte stammen aus einem früheren Build. Buildbefehle und Toolchain: [Entwicklung](docs/ENTWICKLUNG.md); tatsächliche Ergebnisse: [Phase 1](docs/verification/phase-1.md), [Phase 2](docs/verification/phase-2.md), [Phase 3](docs/verification/phase-3.md), [Phase 4](docs/verification/phase-4.md). Der formale Clean-Checkout-/CI-Nachweis bleibt offen.

## Dokumentation

- [Projektskizze und Produktentscheidungen](docs/PROJEKTSKIZZE.md)
- [Architektur und Sicherheitsverträge](docs/ARCHITEKTUR.md)
- [Phasenplan mit Abnahmekriterien](docs/UMSETZUNGSPLAN.md)
- [Coding-Anweisungen und Startprompt für Codex](docs/CODEX-ANWEISUNGEN.md)
- [Recherche, Quellen und SwitchHosts-Codeanalyse](docs/RECHERCHE.md)

Version 1 umfasst lokale und entfernte Profile, einzelne Eintragsschalter, Ordner, Editor, Menüleiste, Konfliktprüfung, Vorschau, Backups, Wiederherstellung sowie Import/Export einschließlich einer ausdrücklich dokumentierten SwitchHosts-Kompatibilität. Änderungen bleiben bis zur bewussten Deaktivierung bestehen.

Geplant ist ein Download mit Ad-hoc-Signatur, ohne Developer ID, Notarisierung, Apple-Account oder App Store. Die Erststartfreigabe erfolgt lokal in macOS. Der Quellcode steht unter der [MIT-Lizenz](LICENSE).
