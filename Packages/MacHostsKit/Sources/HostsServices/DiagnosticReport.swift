import Foundation
import HostsCore

/// Redacted support report. It contains counts, states and error categories only:
/// no profile names, profile text, hostnames from profiles, URLs or file contents.
public struct DiagnosticReport: Equatable, Sendable {
  public struct Environment: Equatable, Sendable {
    public let appVersion: String
    public let build: String
    public let operatingSystem: String
    public init(appVersion: String, build: String, operatingSystem: String) {
      self.appVersion = appVersion
      self.build = build
      self.operatingSystem = operatingSystem
    }

    public static var current: Environment {
      let info = Bundle.main.infoDictionary ?? [:]
      return Environment(
        appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
        build: info["CFBundleVersion"] as? String ?? "?",
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString)
    }
  }

  public let lines: [String]

  public init(
    environment: Environment, load: WorkspaceLoad?, draft: Workspace?, unsavedChanges: Bool,
    systemStatus: SystemObservation, observationFailure: SystemFileReadFailure?,
    systemDiagnostics: Int?, loginItem: String, now: Date = Date()
  ) {
    var lines = [
      "MacHosts diagnostic report",
      "generated: \(now.formatted(.iso8601))",
      "app: \(environment.appVersion) (\(environment.build))",
      "os: \(environment.operatingSystem)",
      "systemApply: \(SystemApplyStatus.availability)",
      "loginItem: \(loginItem)",
    ]
    if let load {
      lines.append("workspace.schema: \(load.snapshot?.schemaVersion ?? -1)")
      lines.append("workspace.readOnly: \(load.readOnlyReason.map { "\($0)" } ?? "no")")
      lines.append("workspace.recoveryCandidate: \(load.recoveryCandidate != nil)")
      lines.append("workspace.pendingApply: \(load.snapshot?.pendingApply != nil)")
      if let applied = load.snapshot?.applied {
        lines.append("applied.readback: \(applied.receipt.readback.rawValue)")
        lines.append("applied.cacheFlush: \(applied.receipt.cacheFlush.rawValue)")
        lines.append(
          "applied.profiles: \(applied.workspace.profiles.filter(\.isEnabled).count) enabled")
      } else {
        lines.append("applied: none")
      }
    } else {
      lines.append("workspace: unavailable")
    }
    lines.append("workspace.unsavedChanges: \(unsavedChanges)")
    if let draft {
      let remote = draft.profiles.compactMap(\.remote)
      lines.append(
        "profiles: \(draft.profiles.count) (\(draft.profiles.filter(\.isEnabled).count) desired active, \(remote.count) remote)"
      )
      lines.append("folders: \(draft.folders.count)")
      lines.append("trash: \(draft.trash.count)")
      let bytes = draft.profiles.reduce(0) { $0 + $1.source.utf8.count }
      lines.append("profileBytes: \(bytes)")
      let failures = Dictionary(grouping: remote.compactMap(\.lastFailure), by: \.rawValue)
      for (category, values) in failures.sorted(by: { $0.key < $1.key }) {
        lines.append("remote.failure.\(category): \(values.count)")
      }
      lines.append("remote.neverRefreshed: \(remote.filter { $0.lastRefresh == nil }.count)")
    }
    lines.append("system.status: \(systemStatus)")
    if let observationFailure { lines.append("system.readFailure: \(observationFailure)") }
    if let systemDiagnostics { lines.append("system.parserDiagnostics: \(systemDiagnostics)") }
    self.lines = lines
  }

  public var text: String { lines.joined(separator: "\n") + "\n" }
}
