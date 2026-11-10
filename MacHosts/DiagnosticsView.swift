import AppKit
import HostsServices
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Shows the complete redacted report before it can leave the app. Export is explicit
/// and creates a new file through the standard save panel.
struct DiagnosticsView: View {
  let model: AppModel
  @State private var exportFailed = false

  private var report: DiagnosticReport {
    let failure: SystemFileReadFailure? =
      if case .unreadable(let value) = model.system.observation { value } else { nil }
    return DiagnosticReport(
      environment: .current, load: model.editor?.persisted, draft: model.editor?.workspace,
      unsavedChanges: model.editor?.hasUnsavedChanges ?? false,
      systemStatus: model.system.status, observationFailure: failure,
      systemDiagnostics: model.system.contents?.diagnostics.count,
      loginItem: loginItemDescription(SMAppService.mainApp.status))
  }

  var body: some View {
    let text = report.text
    VStack(alignment: .leading, spacing: 10) {
      Text("Diagnostics").font(.headline)
      Text(
        "This report contains states, counts and error categories only. It contains no profile names, profile contents, hostnames or addresses of remote sources."
      )
      .font(.caption)
      ScrollView {
        Text(verbatim: text)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("diagnosticReport")
      if exportFailed {
        Text("The report could not be saved.").foregroundStyle(.red)
      }
      HStack {
        Button("Check system file again", action: model.refresh)
        Spacer()
        Button("Copy report") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
        Button("Save report…") { export(text) }
      }
    }
    .padding(20)
    .frame(minWidth: 520, minHeight: 420)
    .onAppear { model.start() }
  }

  private func export(_ text: String) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "MacHosts-diagnostics.txt"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try Data(text.utf8).write(to: url, options: .atomic)
      exportFailed = false
    } catch {
      exportFailed = true
    }
  }
}
