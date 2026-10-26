import AppKit
import HostsCore
import HostsServices
import SwiftUI
import UniformTypeIdentifiers

/// Exchange uses frozen text, never a system destination or an apply operation.
struct HostsTextExchangeView: View {
  let editor: ProfileWorkspaceModel
  @State private var profile: Profile?
  let imported: (UUID) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var service = HostsTextExchange()
  @State private var snapshot: HostsTextImport?
  @State private var name = ""
  @State private var busy = false
  @State private var failure: HostsTextExchangeFailure?
  @State private var exported = false
  @State private var importFailed = false
  @State private var mode = HostsTextExportMode.source

  init(editor: ProfileWorkspaceModel, profile: Profile?, imported: @escaping (UUID) -> Void) {
    self.editor = editor
    _profile = State(initialValue: profile)
    self.imported = imported
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import / Export…").font(.title2)
      Text("Import creates a new inactive local profile. System settings stay unchanged.")
      Button("Choose hosts text file…") { chooseImport() }
        .disabled(busy || editor.isReadOnly)
        .accessibilityIdentifier("chooseHostsImport")
      if let snapshot {
        TextField("Profile name", text: $name)
        Text(
          "Review the complete source before importing. Invalid lines remain editable diagnostics.")
        NativeProfileEditor(source: snapshot.source, isEditable: false, jump: nil) { _ in
          snapshot.source
        }
        if !snapshot.document.diagnostics.isEmpty {
          Text("The source contains diagnostics. Review it before enabling the imported profile.")
          ScrollView {
            VStack(alignment: .leading) {
              ForEach(Array(snapshot.document.diagnostics.prefix(20).enumerated()), id: \.offset) {
                _, diagnostic in
                HStack {
                  if let line = diagnostic.line { Text("Line \(line):") }
                  Text(diagnosticText(diagnostic.code))
                }
              }
              if snapshot.document.diagnostics.count > 20 {
                Text("Only the first 20 diagnostics are shown.")
              }
            }
          }
          .frame(maxHeight: 100)
        }
        Button("Import inactive profile") {
          if let id = editor.importText(snapshot, name: name) {
            imported(id)
          } else {
            importFailed = true
          }
        }
        .disabled(busy || editor.isReadOnly)
        .accessibilityIdentifier("confirmHostsImport")
        if importFailed {
          Text("Import could not be added. Check the profile name and workspace limits.")
            .foregroundStyle(.red)
        }
      }
      Divider()
      if let profile {
        Text(verbatim: profile.name).fontWeight(.medium)
        Text("Export uses the draft captured when this window opened.")
        Picker("Export content", selection: $mode) {
          Text("Original source (including disabled and invalid lines)")
            .tag(HostsTextExportMode.source)
          Text("Enabled entries only (requires valid source)")
            .tag(HostsTextExportMode.enabledEntries)
        }
        .disabled(busy)
        Text("Choose a new filename. Existing files are never overwritten.")
        Button("Export hosts text…") { export(profile) }
          .disabled(busy)
          .accessibilityIdentifier("exportHostsText")
      } else {
        Text("Select a profile to export its draft.")
      }
      if busy { ProgressView() }
      if let failure { Text(failureMessage(failure)).foregroundStyle(.red) }
      if exported { Text("Export saved.") }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(busy)
      }
    }
    .padding(24)
    .frame(minWidth: 700, minHeight: snapshot == nil ? 300 : 600)
    .interactiveDismissDisabled(busy)
  }

  private func chooseImport() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.plainText, .data]
    busy = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        busy = false
        return
      }
      failure = nil
      exported = false
      snapshot = nil
      importFailed = false
      Task { @MainActor in
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
          if scoped { url.stopAccessingSecurityScopedResource() }
          busy = false
        }
        do {
          snapshot = try await service.read(url)
          name = url.deletingPathExtension().lastPathComponent
        } catch {
          failure = (error as? HostsTextExchangeFailure) ?? .unreadable
        }
      }
    }
  }

  private func export(_ profile: Profile) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "hosts") ?? .plainText]
    // User profile names never become path components.
    panel.nameFieldStringValue = "profile.hosts"
    busy = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        busy = false
        return
      }
      failure = nil
      exported = false
      Task { @MainActor in
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
          if scoped { url.stopAccessingSecurityScopedResource() }
          busy = false
        }
        do {
          let data = try await service.data(source: profile.source, mode: mode)
          try await service.writeNew(data, to: url)
          exported = true
        } catch {
          failure = (error as? HostsTextExchangeFailure) ?? .writeFailed
        }
      }
    }
  }

  private func failureMessage(_ failure: HostsTextExchangeFailure) -> String {
    switch failure {
    case .unreadable: String(localized: "The selected file could not be read.")
    case .sizeLimit: String(localized: "Hosts text must be at most 1 MiB. Nothing was truncated.")
    case .unsupportedEncoding: String(localized: "Choose UTF-8 text without a byte-order mark.")
    case .incompleteDocument: String(localized: "Hosts text exceeds the 50,000-line limit.")
    case .invalidEntries: String(localized: "Fix source diagnostics or export the original source.")
    case .destinationExists:
      String(localized: "That filename already exists. Choose a new filename.")
    case .writeFailed:
      String(
        localized: "Export failed. A partial new file may remain; choose a new filename to retry.")
    }
  }
}
