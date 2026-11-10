import AppKit
import HostsCore
import HostsServices
import SwiftUI
import UniformTypeIdentifiers

/// Exchange uses frozen text, never a system destination or an apply operation.
struct HostsTextExchangeView: View {
  let editor: ProfileWorkspaceModel
  @State private var profile: Profile?
  @State private var workspace: Workspace
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
    _workspace = State(initialValue: editor.workspace)
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
      WorkspaceJSONExchangeView(editor: editor, workspace: workspace, busy: $busy)
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

/// Portable JSON is append-only here; replacement needs a separate backup/review flow.
private struct WorkspaceJSONExchangeView: View {
  let editor: ProfileWorkspaceModel
  let workspace: Workspace
  @State private var service = WorkspaceExchange()
  @State private var review: WorkspaceExchangeDocument?
  @State private var selected: UUID?
  @State private var includedProfiles: Set<UUID> = []
  @State private var includeAllFolders = true
  @State private var inspected: HostsTextImport?
  @Binding var busy: Bool
  @State private var message: String?
  @State private var showingReview = false
  @State private var confirmingReplace = false
  @State private var backupNames: [String] = []
  @State private var restoring: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("MacHosts JSON").font(.headline)
      Text(
        "Exchange all current profiles and folders. Remote sources become local cached copies. Activation, trash and system history are omitted."
      )
      Text("JSON export uses the workspace captured when this window opened.")
      HStack {
        Button("Review JSON import…") { chooseImport() }
          .accessibilityIdentifier("chooseJSONImport")
          .disabled(busy || editor.isReadOnly)
        Button("Export workspace JSON…") { export() }
          .accessibilityIdentifier("exportWorkspaceJSON")
          .disabled(busy)
      }
      if !backupNames.isEmpty {
        Menu("Restore draft from backup…") {
          ForEach(backupNames, id: \.self) { name in
            Button(backupLabel(name)) { restoring = name }
          }
        }
        .accessibilityIdentifier("restoreWorkspaceBackup")
        .fixedSize()
        .disabled(busy || editor.isReadOnly)
      }
      if busy { ProgressView() }
      if let message { Text(message).accessibilityIdentifier("jsonExchangeMessage") }
    }
    .task { backupNames = await editor.backups() }
    .confirmationDialog(
      "Restore the workspace draft from this backup?",
      isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })
    ) {
      Button("Back up current draft and restore", role: .destructive) {
        guard let name = restoring else { return }
        Task { await replace { await editor.restoreBackup(name) } }
      }
    } message: {
      Text(
        "Profiles, folders and deleted profiles are restored as they were saved. The current draft is backed up first. The system hosts file is not changed."
      )
    }
    .sheet(isPresented: $showingReview) {
      if let review {
        let folderNames = Dictionary(uniqueKeysWithValues: review.folders.map { ($0.id, $0.name) })
        VStack(alignment: .leading, spacing: 12) {
          Text("Review JSON import").font(.title2)
          Text(
            "Append adds the selected profiles inactive with new identities; existing profiles and same-name folders remain separate. Replace swaps the whole draft only after a confirmed backup."
          )
          Text("Profiles: \(review.profiles.count), folders: \(review.folders.count)")
          HStack {
            Button("Select all profiles") { includedProfiles = Set(review.profiles.map(\.id)) }
            Button("Deselect all profiles") { includedProfiles = [] }
            Text("Selected profiles: \(includedProfiles.count)")
          }
          Toggle("Include all folders, including empty folders", isOn: $includeAllFolders)
          Text("Required parent folders are always included with selected profiles.")
            .font(.caption)
          if !review.folders.isEmpty {
            DisclosureGroup("Folders in file") {
              ScrollView {
                LazyVStack(alignment: .leading) {
                  ForEach(review.folders) { folder in
                    let parent = folder.parentID.flatMap { folderNames[$0] }
                    Text(verbatim: parent.map { $0 + " / " + folder.name } ?? folder.name)
                  }
                }
              }.frame(maxHeight: 100)
            }
          }
          Picker("Profile source", selection: $selected) {
            ForEach(review.profiles, id: \.id) { profile in
              Text(verbatim: profile.name).tag(Optional(profile.id))
            }
          }
          Text(
            "Same-name profiles: \(review.profiles.filter { imported in includedProfiles.contains(imported.id) && editor.workspace.profiles.contains { $0.name == imported.name } }.count)"
          )
          if let profile = review.profiles.first(where: { $0.id == selected }) {
            Toggle(
              "Include this profile",
              isOn: Binding(
                get: { includedProfiles.contains(profile.id) },
                set: { included in
                  if included {
                    includedProfiles.insert(profile.id)
                  } else {
                    includedProfiles.remove(profile.id)
                  }
                })
            )
            .accessibilityIdentifier("includeJSONProfile")
            Text(
              "Review the complete source before importing. Invalid lines remain editable diagnostics."
            )
            NativeProfileEditor(source: profile.source, isEditable: false, jump: nil) { _ in
              profile.source
            }.id(profile.id)
            if let inspected, inspected.source == profile.source,
              !inspected.document.diagnostics.isEmpty
            {
              ScrollView {
                VStack(alignment: .leading) {
                  ForEach(
                    Array(inspected.document.diagnostics.prefix(20).enumerated()), id: \.offset
                  ) { _, diagnostic in
                    HStack {
                      if let line = diagnostic.line { Text("Line \(line):") }
                      Text(diagnosticText(diagnostic.code))
                    }
                  }
                  if inspected.document.diagnostics.count > 20 {
                    Text("Only the first 20 diagnostics are shown.")
                  }
                }
              }.frame(maxHeight: 100)
            }
          }
          if let message { Text(message).foregroundStyle(.red) }
          HStack {
            Button("Cancel") { showingReview = false }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Replace workspace…") { confirmingReplace = true }
              .accessibilityIdentifier("replaceWorkspaceJSON")
              .disabled(
                editor.isReadOnly
                  || (includedProfiles.isEmpty && (!includeAllFolders || review.folders.isEmpty)))
            Button("Append inactive profiles") {
              do {
                let subset = try review.selecting(
                  profileIDs: includedProfiles, includeAllFolders: includeAllFolders)
                if editor.importWorkspace(subset) {
                  showingReview = false
                  message = String(localized: "JSON import added. Profiles remain inactive.")
                } else {
                  message = String(
                    localized:
                      "Import could not be added. Check the profile name and workspace limits.")
                }
              } catch { message = errorText(error) }
            }.disabled(
              editor.isReadOnly
                || (includedProfiles.isEmpty && (!includeAllFolders || review.folders.isEmpty)))
          }
        }.padding(24).frame(width: 720, height: 720)
          .confirmationDialog(
            "Replace the entire workspace draft?", isPresented: $confirmingReplace
          ) {
            Button("Back up and replace", role: .destructive) {
              do {
                let subset = try review.selecting(
                  profileIDs: includedProfiles, includeAllFolders: includeAllFolders)
                showingReview = false
                Task { await replace { await editor.replaceWorkspace(with: subset) } }
              } catch { message = errorText(error) }
            }
          } message: {
            Text(
              "All current profiles, folders and deleted profiles are removed from the draft and replaced by the selected import as inactive profiles. A backup of the current workspace is saved first and can be restored here. The system hosts file is not changed."
            )
          }
          .task(id: selected) {
            inspected = nil
            guard let source = review.profiles.first(where: { $0.id == selected })?.source else {
              return
            }
            do {
              let result = try await service.inspect(source)
              guard !Task.isCancelled else { return }
              inspected = result
            } catch { message = errorText(error) }
          }
      }
    }
  }

  private func replace(_ operation: () async -> String?) async {
    busy = true
    defer { busy = false }
    if await operation() != nil {
      message = String(
        localized: "Workspace draft replaced. A backup was saved. Profiles remain inactive.")
    } else if let failure = editor.editFailure {
      message = editFailureText(failure)
    } else {
      message = String(
        localized:
          "The workspace was not replaced. Save pending changes, check limits, and try again.")
    }
    backupNames = await editor.backups()
  }

  /// Backup names carry a UTC timestamp (`workspace.backup-YYYYMMDD-HHMMSS-id.json`).
  private func backupLabel(_ name: String) -> String {
    let parts = name.split(separator: "-")
    guard parts.count >= 3,
      let date = try? Date(
        String(parts[1] + parts[2]),
        strategy: Date.ParseStrategy(
          format:
            "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
          timeZone: .gmt))
    else { return name }
    return date.formatted(date: .abbreviated, time: .standard)
  }

  private func chooseImport() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.json]
    busy = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        busy = false
        return
      }
      Task { @MainActor in
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
          if scoped { url.stopAccessingSecurityScopedResource() }
          busy = false
        }
        do {
          review = try await service.read(url)
          selected = review?.profiles.first?.id
          includedProfiles = Set(review?.profiles.map(\.id) ?? [])
          includeAllFolders = true
          message = nil
          showingReview = true
        } catch { message = errorText(error) }
      }
    }
  }

  private func export() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "MacHosts.json"
    busy = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        busy = false
        return
      }
      Task { @MainActor in
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
          if scoped { url.stopAccessingSecurityScopedResource() }
          busy = false
        }
        do {
          let document = try await service.capture(workspace)
          try await service.writeNew(document, to: url)
          message = String(localized: "Export saved.")
        } catch { message = errorText(error) }
      }
    }
  }

  private func errorText(_ error: any Error) -> String {
    if let failure = error as? WorkspaceExchangeFailure {
      return switch failure {
      case .unsupportedVersion: String(localized: "This MacHosts JSON version is not supported.")
      case .invalidDocument:
        String(localized: "The JSON document is invalid. Nothing was imported.")
      }
    }
    if let failure = error as? HostsTextExchangeFailure {
      return switch failure {
      case .destinationExists:
        String(localized: "That filename already exists. Choose a new filename.")
      case .writeFailed:
        String(
          localized: "Export failed. A partial new file may remain; choose a new filename to retry."
        )
      case .sizeLimit:
        String(
          localized:
            "JSON must fit the 32 MiB workspace and 1 MiB profile limits. Nothing was truncated.")
      default:
        String(localized: "The JSON file could not be read completely. Nothing was imported.")
      }
    }
    return String(localized: "The JSON document is invalid. Nothing was imported.")
  }
}
