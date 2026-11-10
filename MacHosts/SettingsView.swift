import HostsServices
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  let model: AppModel
  @AppStorage(AppSettings.showsMenuBarExtra) private var showsMenuBarExtra = true
  @AppStorage(AppSettings.refreshRemoteOnLaunch) private var refreshOnLaunch = false
  @AppStorage(AppSettings.remoteRefreshHours) private var refreshHours = 0

  var body: some View {
    Form {
      Section("General") {
        LoginItemControl()
        Toggle("Show in menu bar", isOn: $showsMenuBarExtra)
        Text(
          "Closing all windows keeps MacHosts running in the menu bar. Quitting never changes the system file."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Remote profiles") {
        Toggle("Refresh when MacHosts starts", isOn: $refreshOnLaunch)
        Picker("Refresh while running", selection: $refreshHours) {
          Text("Never").tag(0)
          Text("Every hour").tag(1)
          Text("Every 6 hours").tag(6)
          Text("Every 24 hours").tag(24)
        }
        .onChange(of: refreshHours) { _, _ in model.updateRemoteSchedule() }
        Text(
          "Refreshes run only while MacHosts is open. Downloads update local drafts and are never applied automatically."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// Opt-in login start via SMAppService.mainApp. The control always shows the status
/// reported by the OS, not a stored preference.
struct LoginItemControl: View {
  @State private var status = SMAppService.mainApp.status
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(
        "Open at login",
        isOn: Binding(
          get: { status == .enabled || status == .requiresApproval },
          set: { set($0) })
      )
      .accessibilityIdentifier("openAtLogin")
      switch status {
      case .requiresApproval:
        HStack {
          Text("Approval in System Settings is required.").font(.caption)
          Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
        }
      case .notFound where failed:
        Text("Login start is unavailable for this copy of the app.").font(.caption)
      default:
        EmptyView()
      }
      if failed {
        Text("The login item could not be changed.").font(.caption).foregroundStyle(.red)
      }
    }
    .onAppear { status = SMAppService.mainApp.status }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in status = SMAppService.mainApp.status }
  }

  private func set(_ enabled: Bool) {
    failed = false
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      failed = true
    }
    status = SMAppService.mainApp.status
  }
}

func loginItemDescription(_ status: SMAppService.Status) -> String {
  switch status {
  case .enabled: "enabled"
  case .requiresApproval: "requiresApproval"
  case .notRegistered: "notRegistered"
  case .notFound: "notFound"
  @unknown default: "unknown"
  }
}
