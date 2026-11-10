import AppKit
import HostsCore
import HostsServices
import SwiftUI

/// Menu bar quick access. Checkmarks show only the verified applied state; desired
/// activation is a separate draft toggle. Every system change goes through the same
/// preview in a workspace window as the main window uses.
struct MenuBarContent: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(statusText)
    if let editor = model.editor {
      if editor.hasUnappliedChanges { Text("Drafts not applied to the system") }
      if editor.saveFailed { Text("Drafts could not be saved.") }
      Divider()
      Section("Applied profiles") {
        let applied = appliedProfiles(editor)
        if applied.isEmpty {
          Text("None verified")
        } else {
          ForEach(applied, id: \.self) { name in
            Label {
              Text(verbatim: name)
            } icon: {
              Image(systemName: "checkmark")
            }
          }
        }
      }
      Menu("Desired activation (draft)") {
        ForEach(editor.workspace.profiles) { profile in
          Toggle(
            isOn: Binding(
              get: { profile.isEnabled },
              set: { editor.setEnabled(profile.id, enabled: $0) })
          ) {
            Text(verbatim: profile.name)
          }
        }
      }
      .disabled(editor.isReadOnly || editor.workspace.profiles.isEmpty)
      Button("Preview changes…") { open(.preview) }
        .disabled(editor.isReadOnly)
      if editor.workspace.profiles.contains(where: { $0.kind == .remote }) {
        if model.remote.isRefreshing {
          Text("Refreshing remote profiles…")
        } else {
          Button("Refresh remote profiles") { model.remote.refreshAll(editor: editor) }
            .disabled(editor.isReadOnly)
        }
      }
      if SystemApplyStatus.availability == .unavailable {
        Text("System changes are not available in this build.")
      }
    }
    Divider()
    Button("Open MacHosts") { show(id: "workspace") }
    Button("System file status…") { open(.status) }
    Button("Diagnostics…") { show(id: "diagnostics") }
    SettingsLink { Text("Settings…") }
    Divider()
    Button("Quit MacHosts") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private var statusText: String {
    switch model.system.status {
    case .confirmed: String(localized: "System file matches the last verified apply.")
    case .externalChange: String(localized: "System file changed externally.")
    case .recoveryRequired: String(localized: "An interrupted apply requires recovery.")
    case .unconfirmed: String(localized: "Current system state is unconfirmed.")
    }
  }

  private func appliedProfiles(_ editor: ProfileWorkspaceModel) -> [String] {
    // Only a receipt-bound snapshot counts; a stale or failed apply never shows a checkmark.
    guard model.system.status == .confirmed,
      let applied = editor.persisted.snapshot?.applied
    else { return [] }
    return applied.workspace.profiles.filter(\.isEnabled).map(\.name)
  }

  private func open(_ kind: AppModel.WindowRequest.Kind) {
    model.request(kind)
    show(id: "workspace")
  }

  private func show(id: String) {
    model.start()
    if id != "workspace"
      || !NSApp.windows.contains(where: {
        $0.isVisible && $0.identifier?.rawValue.hasPrefix("workspace") == true
      })
    {
      openWindow(id: id)
    }
    NSApp.activate()
    if id == "workspace" {
      NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("workspace") == true }?
        .makeKeyAndOrderFront(nil)
    }
  }
}
