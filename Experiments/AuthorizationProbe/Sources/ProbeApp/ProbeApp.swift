import AppKit
import Darwin
import ProbeCore
import SwiftUI

@main
struct ProbeApp: App {
  init() {
    guard geteuid() != 0 else { exit(64) }
  }

  var body: some Scene {
    WindowGroup("MacHosts · Authorization Probe") {
      ProbeView()
    }
    .defaultSize(width: 640, height: 420)
  }
}

@MainActor
private struct ProbeView: View {
  @State private var status = "Bereit. Alle Dateitests verwenden eine private Wegwerfdatei."
  @State private var busy = false
  private let vmProbeEnabled = CommandLine.arguments.contains("--enable-vm-auth-probe")

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("MacHosts · Phase 0", systemImage: "network")
        .font(.title)
      Text("Machbarkeitsprototyp – keine Hosts-Verwaltung")
        .font(.headline)
      Text(
        "Der Dateitest arbeitet ohne Administratorrechte. Ein eigener Swift-Prozess wird nicht als Root gestartet."
      )
      Button("Dateitest: Anwenden und exakt wiederherstellen") {
        busy = true
        Task {
          do {
            status = try await runFixtureDemo()
          } catch { status = "Dateitest fehlgeschlagen: \(error)" }
          busy = false
        }
      }
      .disabled(busy)
      Button("Systemdialog prüfen (nur VM, keine Dateischreibvorgänge)") {
        busy = true
        Task {
          do { status = try await AuthorizationIdentityProbe.run() } catch {
            status = "Systemdialog nicht bestätigt: \(error)"
          }
          busy = false
        }
      }
      .disabled(busy || !vmProbeEnabled)
      Text(
        vmProbeEnabled
          ? "VM-Test freigeschaltet. Dies prüft ausschließlich Apples /usr/bin/id."
          : "VM-Test deaktiviert. Freischaltung nur im dokumentierten VM-Testlauf."
      )
      .font(.caption).foregroundStyle(.secondary)
      Divider()
      Text(status).textSelection(.enabled)
      Spacer()
    }
    .padding(24)
  }
}

@concurrent
private func runFixtureDemo() async throws -> String {
  let session = try SandboxSession()
  do {
    let before = try await session.snapshot()
    let request = ProbeRequest(expectedDigest: digest(before), operation: .installExample)
    let receipt = try await session.apply(request)
    try await session.restoreOriginal(expectedDigest: receipt.afterDigest)
    guard try await session.snapshot() == before else { throw ProbeError.recoveryRequired }
    try await session.close()
    return
      "Bestanden: Beispiel übernommen, zurückgelesen und bytegenau wiederhergestellt. Wegwerfdatei entfernt."
  } catch {
    try await session.close()
    throw error
  }
}

private enum AuthorizationIdentityProbe {
  enum Failure: Error {
    case disabled, unavailable, unexpectedResult
    case rejected(Int)
  }

  // No interpolated command or user data. This does not launch our own root code.
  @concurrent
  static func run() async throws -> String {
    guard geteuid() != 0,
      CommandLine.arguments.contains("--enable-vm-auth-probe")
    else { throw Failure.disabled }
    guard
      let script = NSAppleScript(
        source:
          "do shell script \"/usr/bin/id -u\" with administrator privileges")
    else { throw Failure.unavailable }
    var details: NSDictionary?
    let result = script.executeAndReturnError(&details)
    if let details {
      let number = details[NSAppleScript.errorNumber] as? Int ?? 0
      throw Failure.rejected(number)
    }
    guard result.stringValue == "0" else { throw Failure.unexpectedResult }
    return
      "Systemautorisierung für Apples id bestätigt. Sicherer Start eines eigenen Swift-Tools weiterhin nicht nachgewiesen."
  }
}
