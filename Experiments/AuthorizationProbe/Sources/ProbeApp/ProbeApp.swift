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
  @State private var status = "Ready. All file tests use a private disposable file."
  @State private var busy = false
  private let vmProbeEnabled = CommandLine.arguments.contains("--enable-vm-auth-probe")

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("MacHosts · Phase 0", systemImage: "network")
        .font(.title)
      Text("Feasibility prototype – not a hosts manager")
        .font(.headline)
      Text(
        "The file test runs without administrator privileges. It does not launch our Swift code as root."
      )
      Button("File test: apply and restore exact bytes") {
        busy = true
        Task {
          do {
            status = try await runFixtureDemo()
          } catch { status = "File test failed: \(error)" }
          busy = false
        }
      }
      .disabled(busy)
      Button("Check system dialog (VM only, no file writes)") {
        busy = true
        Task {
          do { status = try await AuthorizationIdentityProbe.run() } catch {
            status = "System dialog not confirmed: \(error)"
          }
          busy = false
        }
      }
      .disabled(busy || !vmProbeEnabled)
      Text(
        vmProbeEnabled
          ? "VM test enabled. This checks only Apple's /usr/bin/id."
          : "VM test disabled. Enable only during the documented VM test run."
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
      "Passed: example applied, read back, and restored byte for byte. Disposable file removed."
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
      "System authorization for Apple's id confirmed. Safe launch of our Swift tool remains unproven."
  }
}
