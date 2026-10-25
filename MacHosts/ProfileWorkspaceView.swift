import Foundation
import HostsCore
import HostsServices
import SwiftUI

struct ProfileWorkspaceView: View {
  @Bindable var model: AppModel
  @State private var showsTrash = false
  @State private var showsStatus = false
  @State private var showsFolders = false
  @State private var query = ""
  @State private var searchResult = ProfileSearchResult(hits: [], isTruncated: false)
  @State private var search = ProfileSearch()
  @State private var jump: ProfileEditorJump?
  @FocusState private var searchFocused: Bool

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        TextField("Search all profiles", text: $query)
          .textFieldStyle(.roundedBorder)
          .focused($searchFocused)
          .accessibilityIdentifier("profileSearch")
          .padding(8)
        if query.isEmpty {
          List(selection: $model.selection) {
            if let editor = model.editor {
              if editor.workspace.folders.isEmpty {
                profileRows(editor.workspace.profiles, editor: editor)
              } else {
                Section("Unfiled profiles") {
                  profileRows(
                    editor.workspace.profiles.filter { $0.folderID == nil }, editor: editor)
                }
                ForEach(folderRows(editor.workspace.folders)) { row in
                  Section {
                    profileRows(
                      editor.workspace.profiles.filter { $0.folderID == row.id }, editor: editor)
                  } header: {
                    Text(verbatim: row.path)
                  }
                }
              }
            }
          }
        } else {
          List {
            ForEach(Array(searchResult.hits.enumerated()), id: \.offset) { _, hit in
              Button {
                model.selection = hit.profileID
                jump = ProfileEditorJump(
                  id: UUID(), profileID: hit.profileID,
                  digest: hit.digest, range: hit.range)
              } label: {
                VStack(alignment: .leading) {
                  Text(verbatim: hit.profileName).fontWeight(.medium)
                  if let line = hit.line { Text("Line \(line):") }
                  Text(verbatim: hit.excerpt).lineLimit(2)
                }
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("profileSearchHit")
            }
            if searchResult.isTruncated {
              Text("Showing the first 200 matches. Refine your search.")
            }
            if searchResult.hits.isEmpty { Text("No matching profiles or lines.") }
          }
        }
      }
      .navigationTitle("Profiles")
      .navigationSplitViewColumnWidth(min: 180, ideal: 230)
      .toolbar {
        Button {
          model.newProfile()
        } label: {
          Label("New profile", systemImage: "plus")
        }
        .disabled(model.editor?.isReadOnly != false)
        .accessibilityIdentifier("newProfile")
        Button("Folders", systemImage: "folder") { showsFolders = true }
          .accessibilityIdentifier("manageFolders")
          .disabled(model.editor?.isReadOnly != false)
        Button("Search all profiles", systemImage: "magnifyingglass") { searchFocused = true }
          .keyboardShortcut("f", modifiers: [.command, .shift])
        Button {
          showsTrash = true
        } label: {
          Label("Trash", systemImage: "trash")
        }
      }
    } detail: {
      VStack(spacing: 0) {
        if let editor = model.editor,
          let profile = editor.workspace.profiles.first(where: { $0.id == model.selection })
        {
          ProfileDetailView(editor: editor, profile: profile, jump: jump).id(profile.id)
        } else {
          ContentUnavailableView {
            Label("Your hosts profiles", systemImage: "network")
          } description: {
            Text("Create a local profile to edit your desired hosts configuration.")
          } actions: {
            Button("New profile") { model.newProfile() }
              .disabled(model.editor?.isReadOnly != false)
          }
        }
        Divider()
        workspaceStatus
      }
    }
    .task(id: SearchRequest(query: query, revision: model.editor?.workspace.revision)) {
      guard let workspace = model.editor?.workspace else { return }
      searchResult = ProfileSearchResult(hits: [], isTruncated: false)
      guard !query.isEmpty else { return }
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      let result = await search.search(query, in: workspace)
      guard !Task.isCancelled else { return }
      searchResult = result
    }
    .sheet(isPresented: $showsFolders) {
      if let editor = model.editor { FolderManagerView(editor: editor) }
    }
    .sheet(isPresented: $showsTrash) { trash }
    .sheet(isPresented: $showsStatus) {
      VStack {
        SystemObservationView(
          model: model.system, refresh: model.refresh, restart: model.restartObservation)
        Button("Done") { showsStatus = false }.keyboardShortcut(.cancelAction)
      }
      .padding(24)
      .frame(width: 580)
    }
    .onChange(of: model.editor?.persisted.readOnlyReason) { _, _ in
      if let editor = model.editor { model.system.updateWorkspace(editor.persisted) }
    }
    .onChange(of: model.editor?.persisted.snapshot?.generation) { _, _ in
      if let editor = model.editor { model.system.updateWorkspace(editor.persisted) }
    }
  }

  @ViewBuilder
  private func profileRows(_ profiles: [Profile], editor: ProfileWorkspaceModel) -> some View {
    ForEach(profiles) { profile in
      HStack {
        Image(systemName: profile.isEnabled ? "checkmark.circle" : "circle")
          .accessibilityLabel(profile.isEnabled ? Text("Desired active") : Text("Desired inactive"))
        Text(verbatim: profile.name)
        if profile.kind == .remote { Image(systemName: "lock") }
      }
      .tag(profile.id)
      .contextMenu {
        Button("Duplicate as local profile") {
          model.selection = editor.duplicate(profile.id, name: profile.name)
        }
        Button("Move up") { editor.move(profile.id, by: -1) }
        Button("Move down") { editor.move(profile.id, by: 1) }
        Menu("Move to folder") {
          Button("Unfiled profiles") { editor.moveToFolder(profile.id, folderID: nil) }
          ForEach(folderRows(editor.workspace.folders)) { row in
            Button {
              editor.moveToFolder(profile.id, folderID: row.id)
            } label: {
              Text(verbatim: row.path)
            }
          }
        }
        Divider()
        Button("Move to trash") {
          editor.delete(profile.id)
          model.selection = nil
        }
      }
      .disabled(editor.isReadOnly)
    }
  }

  private var workspaceStatus: some View {
    VStack(alignment: .leading, spacing: 6) {
      if model.isPrivateTest {
        Text("Private test workspace").accessibilityIdentifier("privateTestWorkspace")
      }
      if let editor = model.editor {
        if editor.isReadOnly {
          Text("Workspace is read-only. Its data has been preserved.")
        }
        if editor.saveFailed {
          HStack {
            Text("Drafts could not be saved.").foregroundStyle(.red)
            Button("Retry saving") { Task { _ = await editor.flush() } }
          }
        } else if editor.isSaving || editor.hasUnsavedChanges {
          Text("Saving local drafts…")
        } else {
          Text("Local drafts saved.").accessibilityIdentifier("draftSaved")
        }
        if editor.hasUnappliedChanges { Text("Not applied to the system.") }
        if let failure = editor.editFailure {
          HStack {
            Text(editFailureText(failure)).foregroundStyle(.red)
            Button("Dismiss") { editor.clearEditFailure() }
          }
        }
      } else {
        Text("Workspace could not be opened for normal use. Its data has been preserved.")
        Button("Check again", action: model.refresh)
      }
      HStack {
        Text("System changes are not available in this build.")
          .accessibilityIdentifier("systemApplyUnavailable")
        Spacer()
        Button("System file status") { showsStatus = true }
      }
    }
    .font(.callout)
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var trash: some View {
    VStack(alignment: .leading) {
      Text("Trash").font(.title2)
      if let editor = model.editor {
        List(editor.workspace.trash, id: \.profile.id) { item in
          HStack {
            Text(item.profile.name)
            Spacer()
            Button("Restore inactive") {
              editor.restore(item.profile.id)
              model.selection = item.profile.id
            }.disabled(editor.isReadOnly)
          }
        }
      }
      Button("Done") { showsTrash = false }.keyboardShortcut(.cancelAction)
    }
    .padding()
    .frame(width: 500, height: 320)
  }
}

private struct ProfileDetailView: View {
  let editor: ProfileWorkspaceModel
  let profile: Profile
  let jump: ProfileEditorJump?
  @State private var name = ""
  @State private var showsEntries = false

  private var document: HostsDocument {
    HostsDocument.parse(Data(profile.source.utf8), context: .profile)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        TextField("Profile name", text: $name)
          .onSubmit { editor.rename(profile.id, name: name) }
          .onChange(of: profile.name) { _, value in name = value }
          .accessibilityIdentifier("profileName")
        Button("Rename") { editor.rename(profile.id, name: name) }
        Toggle(
          "Desired active",
          isOn: Binding(
            get: { profile.isEnabled }, set: { editor.setEnabled(profile.id, enabled: $0) })
        )
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("profileEnabled")
      }
      .disabled(editor.isReadOnly)
      if profile.kind == .remote {
        HStack {
          Text("Remote content is read-only.")
          Button("Duplicate as local profile") {
            _ = editor.duplicate(profile.id, name: profile.name)
          }
          .disabled(editor.isReadOnly)
        }
      }
      NativeProfileEditor(
        source: profile.source, isEditable: !editor.isReadOnly && profile.kind == .local,
        jump: jump?.profileID == profile.id ? jump : nil,
        onChange: {
          editor.setSource(profile.id, source: $0)
          return editor.workspace.profiles.first(where: { $0.id == profile.id })?.source
            ?? profile.source
        })
      if !document.diagnostics.isEmpty {
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(Array(document.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
              HStack {
                if let line = diagnostic.line { Text("Line \(line):") }
                Text(diagnosticText(diagnostic.code))
              }
            }
          }
        }
        .frame(maxHeight: 100)
        .foregroundStyle(.red)
        .accessibilityIdentifier("profileDiagnostics")
      }
      DisclosureGroup("Entry switches", isExpanded: $showsEntries) {
        ScrollView {
          LazyVStack(alignment: .leading) {
            ForEach(document.lines, id: \.number) { line in
              if case .entry(let entry) = line.kind {
                Toggle(
                  isOn: Binding(
                    get: { entry.isEnabled },
                    set: { _ in
                      editor.toggleLine(
                        profile.id, number: line.number,
                        expectedDigest: ContentDigest(document.data))
                    })
                ) {
                  Text(
                    verbatim:
                      "\(line.number): \(entry.address.canonical) \(entry.hostnames.joined(separator: " "))"
                  )
                  .font(.system(.body, design: .monospaced))
                }
                .toggleStyle(.checkbox)
                .disabled(editor.isReadOnly || profile.kind == .remote)
              }
            }
          }
        }.frame(maxHeight: 160)
      }
      Text(
        "Activation changes the local draft. System changes require a separate preview and authorization."
      )
      .font(.caption)
    }
    .padding()
    .onAppear { name = profile.name }
  }
}

private func editFailureText(_ failure: WorkspaceFailure) -> String {
  switch failure {
  case .invalidName:
    String(localized: "Enter a valid, nonempty profile name (up to 200 UTF-8 bytes).")
  case .limitExceeded:
    String(
      localized:
        "The change exceeds a profile or workspace limit. The previous draft was preserved.")
  case .invalidFolder:
    String(localized: "Choose a valid folder hierarchy (up to 16 levels, without cycles).")
  case .readOnlyProfile: String(localized: "Remote content is read-only.")
  case .staleRevision:
    String(localized: "The profile changed. Retry the action on the current text.")
  default: String(localized: "The change could not be accepted. The previous draft was preserved.")
  }
}

private func diagnosticText(_ code: HostsDiagnostic.Code) -> String {
  switch code {
  case .invalidAddress: String(localized: "Invalid IP address.")
  case .missingHostname: String(localized: "A hostname is required.")
  case .invalidHostname:
    String(localized: "Invalid hostname. Use an ASCII hostname without a URL, port or wildcard.")
  case .reservedMarker, .malformedMarkers: String(localized: "MacHosts block markers are reserved.")
  case .controlCharacter: String(localized: "Unsupported control character.")
  case .unsupportedEncoding: String(localized: "Unsupported text encoding.")
  case .sizeLimit: String(localized: "Profile size limit exceeded.")
  case .lineLimit: String(localized: "Line count limit exceeded.")
  }
}

private struct SearchRequest: Equatable {
  let query: String
  let revision: UInt64?
}

private struct FolderRow: Identifiable {
  let id: UUID
  let path: String
}

/// Preorder is derived from the persisted sibling order. Folder paths are display
/// labels only; IDs remain the identity even when names contain slashes or repeat.
private func folderRows(_ folders: [ProfileFolder], parent: UUID? = nil, path: String = "")
  -> [FolderRow]
{
  folders.filter { $0.parentID == parent }.flatMap { folder in
    let label = path.isEmpty ? folder.name : path + " / " + folder.name
    return [FolderRow(id: folder.id, path: label)]
      + folderRows(folders, parent: folder.id, path: label)
  }
}

private struct FolderManagerView: View {
  let editor: ProfileWorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var selection: UUID?
  @State private var name = ""
  @State private var parentID: UUID?
  @State private var newName = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Group {
        Text("Folders").font(.title2)
        Text("Folders organize profiles without changing activation or composition order.")
        HStack {
          TextField("New folder name", text: $newName)
            .accessibilityIdentifier("newFolderName")
            .onSubmit(createFolder)
          Button("Create folder", action: createFolder)
            .accessibilityIdentifier("createFolder")
        }
        List(selection: $selection) {
          ForEach(folderRows(editor.workspace.folders)) { row in
            Text(verbatim: row.path).tag(row.id)
          }
        }
        if let selection, editor.workspace.folders.contains(where: { $0.id == selection }) {
          HStack {
            TextField("Folder name", text: $name)
              .accessibilityIdentifier("folderName")
            Button("Rename") { editor.renameFolder(selection, name: name) }
          }
          Picker("Parent folder", selection: $parentID) {
            Text("Top level").tag(nil as UUID?)
            ForEach(folderRows(editor.workspace.folders).filter { $0.id != selection }) { row in
              Text(verbatim: row.path).tag(Optional(row.id))
            }
          }
          .accessibilityIdentifier("parentFolder")
          Button("Move folder") { editor.reparentFolder(selection, parentID: parentID) }
          HStack {
            Button("Move up") { editor.moveFolder(selection, by: -1) }
            Button("Move down") { editor.moveFolder(selection, by: 1) }
            Spacer()
            Button("Remove folder, keep profiles") {
              editor.removeFolder(selection)
              self.selection = nil
            }
          }
          Text("Removing a folder moves its profiles and child folders to its parent.")
            .font(.caption)
        }
        if let failure = editor.editFailure {
          Text(editFailureText(failure)).foregroundStyle(.red)
        }
      }.disabled(editor.isReadOnly)
      Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
    }
    .padding(24)
    .frame(width: 580, height: 540)
    .onChange(of: selection) { _, id in
      if let folder = editor.workspace.folders.first(where: { $0.id == id }) {
        name = folder.name
        parentID = folder.parentID
      }
    }
  }

  private func createFolder() {
    if let id = editor.createFolder(name: newName) {
      selection = id
      newName = ""
    }
  }
}
