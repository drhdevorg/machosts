import Foundation
import HostsCore
import HostsServices
import SwiftUI

struct ProfileWorkspaceView: View {
  @Bindable var model: AppModel
  @State private var selection: UUID?
  @State private var showsExchange = false
  @State private var showsPreview = false
  @State private var showsTrash = false
  @State private var showsWorkspaceRecovery = false
  @State private var showsStatus = false
  @State private var showsFolders = false
  @State private var query = ""
  @State private var searchResult = ProfileSearchResult(hits: [], isTruncated: false)
  @State private var search = ProfileSearch()
  @State private var jump: ProfileEditorJump?
  @State private var findRequest: ProfileEditorFindRequest?
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
          List(selection: $selection) {
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
                selection = hit.profileID
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
          newProfile()
        } label: {
          Label("New profile", systemImage: "plus")
        }
        .disabled(model.editor?.isReadOnly != false)
        .accessibilityIdentifier("newProfile")
        Button("Import / Export…", systemImage: "square.and.arrow.up.on.square") {
          showsExchange = true
        }
        .disabled(model.editor == nil)
        .accessibilityIdentifier("textExchange")
        Button("Folders", systemImage: "folder") { showsFolders = true }
          .accessibilityIdentifier("manageFolders")
          .disabled(model.editor?.isReadOnly != false)
        Button("Search all profiles", systemImage: "magnifyingglass") { searchFocused = true }
        Button {
          showsTrash = true
        } label: {
          Label("Trash", systemImage: "trash")
        }
      }
    } detail: {
      VStack(spacing: 0) {
        if let editor = model.editor,
          let profile = editor.workspace.profiles.first(where: { $0.id == selection })
        {
          ProfileDetailView(
            editor: editor, profile: profile, jump: jump, findRequest: findRequest,
            selectProfile: { selection = $0 }
          ) { jump = $0 }
          .id(profile.id)
        } else {
          ContentUnavailableView {
            Label("Your hosts profiles", systemImage: "network")
          } description: {
            Text("Create a local profile to edit your desired hosts configuration.")
          } actions: {
            Button("New profile") { newProfile() }
              .disabled(model.editor?.isReadOnly != false)
          }
        }
        Divider()
        workspaceStatus
      }
    }
    .focusedSceneValue(
      \.workspaceCommands,
      showsExchange || showsPreview || showsTrash || showsWorkspaceRecovery || showsStatus
        || showsFolders
        ? nil : commandActions
    )
    .task(id: SearchRequest(query: query, revision: model.editor?.workspace.revision)) {
      guard let workspace = model.editor?.workspace else { return }
      searchResult = ProfileSearchResult(hits: [], isTruncated: false)
      guard !query.isEmpty else { return }
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      let result = await search.search(query, in: workspace)
      guard !Task.isCancelled else { return }
      searchResult = result
    }
    .sheet(isPresented: $showsExchange) {
      if let editor = model.editor {
        HostsTextExchangeView(
          editor: editor,
          profile: editor.workspace.profiles.first { $0.id == selection }
        ) { id in
          query = ""
          selection = id
          showsExchange = false
        }
      }
    }
    .sheet(isPresented: $showsFolders) {
      if let editor = model.editor { FolderManagerView(editor: editor) }
    }
    .sheet(isPresented: $showsPreview) {
      ChangePreviewView(model: model) { target in
        guard let workspace = model.editor?.workspace,
          let range = target.range(in: workspace)
        else { return }
        query = ""
        selection = target.profileID
        jump = ProfileEditorJump(
          id: UUID(), profileID: target.profileID, digest: target.location.digest, range: range)
        showsPreview = false
      }
    }
    .sheet(isPresented: $showsTrash) { trash }
    .sheet(isPresented: $showsWorkspaceRecovery) {
      if let editor = model.editor {
        WorkspaceRecoveryView(editor: editor) {
          selection = nil
          model.system.updateWorkspace(editor.persisted)
          showsWorkspaceRecovery = false
        }
      }
    }
    .sheet(isPresented: $showsStatus) {
      VStack {
        SystemObservationView(
          model: model.system, refresh: model.refresh, restart: model.restartObservation)
        Button("Done") { showsStatus = false }.keyboardShortcut(.cancelAction)
      }
      .padding(24)
      .frame(minWidth: 700, idealWidth: 850, maxWidth: 1100, maxHeight: 850)
    }
    .onChange(of: model.editor?.workspace.profiles.map(\.id)) { _, ids in
      if let selection, ids?.contains(selection) != true { self.selection = nil }
    }
    .onChange(of: model.editor?.persisted.readOnlyReason) { _, _ in
      if let editor = model.editor { model.system.updateWorkspace(editor.persisted) }
    }
    .onChange(of: model.editor?.persisted.snapshot?.generation) { _, _ in
      if let editor = model.editor { model.system.updateWorkspace(editor.persisted) }
    }
  }

  private func newProfile() {
    guard let id = model.editor?.create(name: String(localized: "New profile")) else { return }
    selection = id
  }

  private var commandActions: WorkspaceCommandActions {
    let profile = model.editor?.workspace.profiles.first { $0.id == selection }
    return WorkspaceCommandActions(
      canEdit: model.editor?.isReadOnly == false,
      hasProfile: profile != nil,
      canReplace: profile?.kind == .local && model.editor?.isReadOnly == false,
      canManageProfile: profile != nil && model.editor?.isReadOnly == false,
      canMoveUp: profile.map { model.editor?.canMove($0.id, by: -1) == true } ?? false,
      canMoveDown: profile.map { model.editor?.canMove($0.id, by: 1) == true } ?? false,
      duplicate: {
        guard let profile,
          let id = model.editor?.duplicate(profile.id, name: profile.name)
        else { return }
        selection = id
      },
      delete: {
        guard let profile else { return }
        model.editor?.delete(profile.id)
      },
      move: { offset in
        guard let profile else { return }
        model.editor?.move(profile.id, by: offset)
      },
      newProfile: newProfile,
      save: { Task { _ = await model.editor?.flush() } },
      search: { searchFocused = true },
      find: { replace in
        guard let profile else { return }
        findRequest = ProfileEditorFindRequest(profileID: profile.id, replace: replace)
      },
      preview: { showsPreview = true },
      folders: { showsFolders = true },
      trash: { showsTrash = true },
      systemStatus: { showsStatus = true },
      exchange: { showsExchange = true })
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
        Group {
          Button("Duplicate as local profile") {
            if let id = editor.duplicate(profile.id, name: profile.name) { selection = id }
          }
          Button("Move up") { editor.move(profile.id, by: -1) }
            .disabled(!editor.canMove(profile.id, by: -1))
          Button("Move down") { editor.move(profile.id, by: 1) }
            .disabled(!editor.canMove(profile.id, by: 1))
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
            if !editor.workspace.profiles.contains(where: { $0.id == profile.id }),
              selection == profile.id
            {
              selection = nil
            }
          }
        }
        .disabled(editor.isReadOnly)
      }
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
          Text(workspaceRecoveryText(editor.persisted.readOnlyReason))
          if editor.canRecoverPrevious {
            Button("Review previous workspace") { showsWorkspaceRecovery = true }
              .accessibilityIdentifier("reviewWorkspaceRecovery")
          }
        }
        if editor.saveFailed {
          HStack {
            Text("Drafts could not be saved.").foregroundStyle(.red)
            Button("Retry saving") { Task { _ = await editor.flush() } }
          }
        } else if editor.isSaving || editor.hasUnsavedChanges {
          Text("Saving local drafts…")
        } else if !editor.isReadOnly {
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
        Button("Preview changes") { showsPreview = true }
          .disabled(model.editor?.isReadOnly != false)
          .accessibilityIdentifier("previewChanges")
        Button("System file status") { showsStatus = true }
      }
    }
    .font(.callout)
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var trash: some View {
    Group {
      if let editor = model.editor {
        TrashReviewView(editor: editor) { id in
          selection = id
          showsTrash = false
        } dismiss: {
          showsTrash = false
        }
      }
    }
  }

}

/// Trash inspection is window-local; only explicit restore mutates the shared draft.
private struct TrashReviewView: View {
  let editor: ProfileWorkspaceModel
  let restored: (UUID) -> Void
  let dismiss: () -> Void
  @State private var selection: UUID?
  @State private var query = ""
  @State private var findRequest: ProfileEditorFindRequest?

  private var items: [TrashedProfile] {
    editor.workspace.trash.filter {
      query.isEmpty
        || $0.profile.name.range(of: query, options: [.caseInsensitive, .literal]) != nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Trash").font(.title2)
      Text(
        "Review deleted profiles before restoring. Restored profiles are inactive; the system file is unchanged."
      )
      HSplitView {
        VStack {
          TextField("Search deleted profile names", text: $query)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("trashSearch")
          List(selection: $selection) {
            ForEach(items, id: \.profile.id) { item in
              Text(verbatim: item.profile.name).tag(item.profile.id)
            }
          }
          .accessibilityIdentifier("trashProfiles")
          if items.isEmpty {
            if editor.workspace.trash.isEmpty {
              Text("Trash is empty.")
            } else {
              Text("No matching deleted profiles.")
            }
          }
        }
        .frame(minWidth: 180, idealWidth: 220)
        VStack(alignment: .leading, spacing: 8) {
          if let item = items.first(where: { $0.profile.id == selection }) {
            Text(verbatim: item.profile.name).font(.headline).textSelection(.enabled)
            LabeledContent(
              "Deleted", value: item.deletedAt.formatted(date: .abbreviated, time: .shortened))
            if item.profile.kind == .remote {
              Text("Remote content is read-only.")
            } else {
              Text("Local profile")
            }
            Button("Find in deleted profile") {
              findRequest = ProfileEditorFindRequest(profileID: item.profile.id, replace: false)
            }
            NativeProfileEditor(
              source: item.profile.source, isEditable: false, jump: nil,
              findRequest: findRequest?.profileID == item.profile.id ? findRequest : nil,
              onChange: { _ in item.profile.source }
            )
            .id(item.profile.id)
            Button("Restore inactive") {
              editor.restore(item.profile.id)
              if editor.workspace.profiles.contains(where: { $0.id == item.profile.id }) {
                restored(item.profile.id)
              }
            }
            .disabled(editor.isReadOnly)
            .accessibilityIdentifier("restoreTrashedProfile")
          } else {
            ContentUnavailableView("Select a deleted profile", systemImage: "trash")
          }
        }
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
      }
      if let failure = editor.editFailure {
        Text(editFailureText(failure)).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(minWidth: 700, idealWidth: 850, minHeight: 450, idealHeight: 600)
    .onChange(of: editor.workspace.trash.map(\.profile.id)) { _, ids in
      if let selection, !ids.contains(selection) { self.selection = nil }
    }
  }
}

private struct ProfileDetailView: View {
  let editor: ProfileWorkspaceModel
  let profile: Profile
  let jump: ProfileEditorJump?
  let findRequest: ProfileEditorFindRequest?
  let selectProfile: (UUID) -> Void
  let navigate: (ProfileEditorJump) -> Void
  @State private var name = ""
  @State private var showsEntries = false
  @State private var entryQuery = ""
  @State private var entryState = ProfileEntrySelection.State.all

  private var parsedDocument: HostsDocument {
    HostsDocument.parse(Data(profile.source.utf8), context: .profile)
  }

  var body: some View {
    let document = parsedDocument
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
      HStack {
        Picker(
          "Move to folder",
          selection: Binding(
            get: { profile.folderID },
            set: { editor.moveToFolder(profile.id, folderID: $0) })
        ) {
          Text("Unfiled profiles").tag(nil as UUID?)
          ForEach(folderRows(editor.workspace.folders)) { row in
            Text(verbatim: row.path).tag(Optional(row.id))
          }
        }
        .accessibilityIdentifier("profileFolder")
        Menu("Profile actions") {
          Button("Duplicate as local profile") {
            if let id = editor.duplicate(profile.id, name: profile.name) { selectProfile(id) }
          }
          Button("Move up") { editor.move(profile.id, by: -1) }
            .disabled(!editor.canMove(profile.id, by: -1))
          Button("Move down") { editor.move(profile.id, by: 1) }
            .disabled(!editor.canMove(profile.id, by: 1))
          Divider()
          Button("Move to trash") { editor.delete(profile.id) }
        }
        .accessibilityIdentifier("profileActions")
      }
      .disabled(editor.isReadOnly)
      if profile.kind == .remote { Text("Remote content is read-only.") }
      NativeProfileEditor(
        source: profile.source, isEditable: !editor.isReadOnly && profile.kind == .local,
        jump: jump?.profileID == profile.id ? jump : nil,
        findRequest: findRequest?.profileID == profile.id ? findRequest : nil,
        onChange: {
          editor.setSource(profile.id, source: $0)
          return editor.workspace.profiles.first(where: { $0.id == profile.id })?.source
            ?? profile.source
        })
      if !document.diagnostics.isEmpty {
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(Array(document.diagnostics.prefix(20).enumerated()), id: \.offset) {
              _, diagnostic in
              let location = ProfileDiagnosticLocation(document: document, line: diagnostic.line)
              Button {
                guard let location else { return }
                navigate(
                  ProfileEditorJump(
                    id: UUID(), profileID: profile.id, digest: location.digest,
                    range: location.range))
              } label: {
                HStack {
                  if let line = diagnostic.line { Text("Line \(line):") }
                  Text(diagnosticText(diagnostic.code))
                }
              }
              .buttonStyle(.link)
              .disabled(location == nil)
              .accessibilityIdentifier("profileDiagnosticLocation")
            }
            if document.diagnostics.count > 20 {
              Text("Only the first 20 diagnostics are shown.")
            }
          }
        }
        .frame(maxHeight: 100)
        .foregroundStyle(.red)
        .accessibilityIdentifier("profileDiagnostics")
      }
      DisclosureGroup("Entry switches", isExpanded: $showsEntries) {
        if showsEntries {
          entryControls(document)
        }
      }
      Text(
        "Activation changes the local draft. System changes require a separate preview and authorization."
      )
      .font(.caption)
    }
    .padding()
    .onAppear { name = profile.name }
  }

  private func entryControls(_ document: HostsDocument) -> some View {
    let matches = ProfileEntrySelection(document: document, query: entryQuery, state: entryState)
    let incomplete = document.diagnostics.contains {
      $0.code == .lineLimit || $0.code == .sizeLimit
    }
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField("Filter entries", text: $entryQuery)
          .accessibilityIdentifier("entryFilter")
        Picker("Entry state", selection: $entryState) {
          Text("All entries").tag(ProfileEntrySelection.State.all)
          Text("Enabled entries").tag(ProfileEntrySelection.State.enabled)
          Text("Disabled entries").tag(ProfileEntrySelection.State.disabled)
        }
      }
      Text("Matching entries: \(matches.rows.count)")
      Text(
        "Each switch affects the entire line, including all hostnames. Bulk actions affect every matching entry."
      )
      .font(.caption)
      HStack {
        Button("Enable matching entries") { setEntries(matches, enabled: true) }
          .disabled(!matches.rows.contains { !$0.isEnabled })
          .accessibilityIdentifier("enableMatchingEntries")
        Button("Disable matching entries") { setEntries(matches, enabled: false) }
          .disabled(!matches.rows.contains { $0.isEnabled })
          .accessibilityIdentifier("disableMatchingEntries")
      }
      .disabled(editor.isReadOnly || profile.kind == .remote || incomplete)
      if incomplete {
        Text("Entry listing is incomplete. Fix the profile limit before using bulk actions.")
      }
      ScrollView {
        LazyVStack(alignment: .leading) {
          ForEach(matches.rows.prefix(200)) { row in
            HStack {
              Toggle(
                isOn: Binding(
                  get: { row.isEnabled },
                  set: { enabled in
                    editor.setLinesEnabled(
                      profile.id, numbers: [row.id], enabled: enabled,
                      expectedDigest: matches.digest)
                  })
              ) {
                Text(verbatim: row.content).font(.system(.body, design: .monospaced))
                  .lineLimit(2)
              }
              .toggleStyle(.checkbox)
              .disabled(editor.isReadOnly || profile.kind == .remote || incomplete)
              Button {
                navigate(
                  ProfileEditorJump(
                    id: UUID(), profileID: profile.id, digest: matches.digest, range: row.range))
              } label: {
                Text("Line \(row.id):")
              }
              .buttonStyle(.link)
              .accessibilityIdentifier("entrySourceLocation")
            }
          }
          if matches.rows.isEmpty { Text("No matching entries.") }
          if matches.rows.count > 200 {
            Text("Only the first 200 entries are shown. Bulk actions include all matches.")
          }
        }
      }.frame(maxHeight: 160)
    }
  }

  private func setEntries(_ matches: ProfileEntrySelection, enabled: Bool) {
    editor.setLinesEnabled(
      profile.id, numbers: Set(matches.rows.map(\.id)), enabled: enabled,
      expectedDigest: matches.digest)
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

func diagnosticText(_ code: HostsDiagnostic.Code, system: Bool = false) -> String {
  switch code {
  case .invalidAddress: String(localized: "Invalid IP address.")
  case .missingHostname: String(localized: "A hostname is required.")
  case .invalidHostname:
    String(localized: "Invalid hostname. Use an ASCII hostname without a URL, port or wildcard.")
  case .reservedMarker: String(localized: "MacHosts block markers are reserved.")
  case .malformedMarkers:
    String(localized: "The MacHosts block markers are missing, repeated or out of order.")
  case .controlCharacter: String(localized: "Unsupported control character.")
  case .unsupportedEncoding: String(localized: "Unsupported text encoding.")
  case .sizeLimit:
    system
      ? String(localized: "System file exceeds the read limit.")
      : String(localized: "Profile size limit exceeded.")
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

/// A frozen read-only plan. Applying remains unavailable until the production boundary is proven.
private struct ChangePreviewView: View {
  let model: AppModel
  let navigate: (ChangePreviewLocation) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var planner = ChangePreviewPlanner()
  @State private var locations: [UUID: [Int: ChangePreviewLocation]] = [:]
  @State private var frozen: ChangePreviewInput?
  @State private var plan: ApplyPlan?
  @State private var failure: ChangePreviewFailure?
  @State private var preparing = false
  @State private var request = 0
  @State private var showsResult = false
  @State private var invalidated = false

  private var input: ChangePreviewInput? {
    guard let editor = model.editor else { return nil }
    let contents = model.system.isMonitoring ? model.system.contents : nil
    return ChangePreviewInput(
      workspace: editor.workspace, load: editor.persisted, contents: contents,
      observationRevision: model.system.previewRevision)
  }

  private var stale: Bool { invalidated || (frozen != nil && frozen != input) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Preview changes").font(.title2)
      Text("These changes affect the entire Mac and remain active after quitting.")
      Text("The preview includes all enabled drafts, including changes in other profiles.")
      Text("System changes are not available in this build.").foregroundStyle(.secondary)
      if preparing { ProgressView("Preparing preview…") }
      if stale {
        Text("This preview is out of date. Prepare it again before reviewing changes.")
          .foregroundStyle(.orange)
          .accessibilityIdentifier("stalePreview")
      }
      if !stale, !preparing {
        if let plan, let frozen {
          ScrollView {
            VStack(alignment: .leading, spacing: 10) {
              Text("Enabled profiles").font(.headline)
              ForEach(frozen.workspace.profiles.filter(\.isEnabled)) { profile in
                Text(verbatim: profile.name)
              }
              if plan.activeProfileIDs.isEmpty { Text("No profiles enabled.") }
              if plan.operation == .noChange { Text("No system file changes.") }
              if plan.operation == .removeManagedBlock {
                Text("The MacHosts managed block will be removed.")
              }
              if plan.operation == .replaceManagedBlock && plan.previousManagedDigest == nil {
                Text("A MacHosts managed block will be appended. A separator may be added.")
              }
              mappings(plan.added, title: "Added mappings", workspace: frozen.workspace)
              mappings(
                plan.removed, title: "Removed mappings", workspace: frozen.workspace,
                navigable: false)
              Text("The complete file views also show comment and formatting changes.").font(
                .caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 240)
          Picker("File view", selection: $showsResult) {
            Text("Current file").tag(false)
            Text("Proposed file").tag(true)
          }.pickerStyle(.segmented)
          let source = String(decoding: showsResult ? plan.after : plan.before, as: UTF8.self)
          NativeProfileEditor(source: source, isSystem: true, isEditable: false, jump: nil) { _ in
            source
          }
          .frame(minHeight: 230)
          .id(showsResult)
        } else if let failure {
          failureView(failure)
        }
      }
      HStack {
        Button("Check again", action: model.refresh)
        Button("Prepare preview again") { request += 1 }.disabled(preparing)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(minWidth: 760, idealWidth: 950, minHeight: 500, idealHeight: 760)
    .onChange(of: input) { _, _ in
      if frozen != nil && frozen != input { invalidated = true }
    }
    .task(id: request) {
      preparing = true
      frozen = nil
      invalidated = false
      plan = nil
      locations = [:]
      failure = nil
      guard let editor = model.editor, await editor.flush(), !Task.isCancelled else {
        failure = .unsavedDraft
        preparing = false
        return
      }
      let captured = input
      frozen = captured
      invalidated = false
      do {
        guard let captured else { throw ChangePreviewFailure.unavailable }
        let result = try await planner.prepare(captured)
        guard !Task.isCancelled else { return }
        plan = result
      } catch let error as ChangePreviewFailure {
        failure = error
      } catch {
        if !Task.isCancelled { failure = .unavailable }
      }
      if let captured, !Task.isCancelled {
        do {
          locations = try await planner.locations(in: captured, plan: plan, failure: failure)
        } catch {
          locations = [:]
        }
      }
      preparing = false
    }
  }

  private func mappings(
    _ values: [ComposedMapping], title: LocalizedStringKey, workspace: Workspace,
    navigable: Bool = true
  ) -> some View {
    VStack(alignment: .leading) {
      Text(title).font(.headline)
      if values.isEmpty { Text("None") }
      ForEach(Array(values.prefix(100).enumerated()), id: \.offset) { _, mapping in
        Text(verbatim: mapping.address.canonical + " " + mapping.hostname)
          .font(.system(.body, design: .monospaced))
        ForEach(Array(mapping.origins.prefix(20).enumerated()), id: \.offset) { _, origin in
          HStack {
            if let id = origin.profileID,
              let profile = workspace.profiles.first(where: { $0.id == id })
            {
              sourceLink(profileID: id, line: origin.line, name: profile.name, enabled: navigable)
            } else {
              Text("System file")
            }
            Text("Line \(origin.line):")
          }.font(.caption)
        }
        if mapping.origins.count > 20 { Text("Only the first 20 source locations are shown.") }
      }
      if values.count > 100 {
        Text("Only the first 100 mappings are listed. Review the complete file views.")
      }
    }
  }

  @ViewBuilder
  private func sourceLink(profileID: UUID, line: Int?, name: String, enabled: Bool = true)
    -> some View
  {
    if enabled, let frozen, let line, let target = locations[profileID]?[line] {
      Button {
        guard !stale, frozen == input else { return }
        navigate(target)
      } label: {
        Text(verbatim: name)
      }
      .buttonStyle(.link)
      .help("Show source line in profile")
      .accessibilityLabel(Text(verbatim: name + ", ") + Text("Line \(line):"))
      .accessibilityIdentifier("previewSourceLink")
    } else {
      Text(verbatim: name)
    }
  }

  @ViewBuilder
  private func failureView(_ failure: ChangePreviewFailure) -> some View {
    switch failure {
    case .unavailable:
      Text(
        "A readable system file and writable workspace are required. Check the system file status.")
    case .unsavedDraft:
      Text("Save all drafts successfully before preparing a preview.")
    case .recoveryRequired:
      Text("An interrupted apply requires recovery.")
    case .plan(.managedBlockChanged):
      Text(
        "The managed block is unrecognized or changed externally. Review system file status before continuing."
      )
    case .plan(.conflicts(let conflicts)):
      Text("Conflicting addresses block these changes.").font(.headline)
      ScrollView {
        VStack(alignment: .leading) {
          ForEach(Array(conflicts.prefix(100).enumerated()), id: \.offset) { _, conflict in
            mappings(
              conflict.mappings, title: "Conflicting mappings",
              workspace: frozen?.workspace ?? Workspace())
          }
          if conflicts.count > 100 { Text("Only the first 100 conflicts are shown.") }
        }
      }
    case .plan(.invalidDocuments(let diagnostics)):
      Text("Correct parser diagnostics before continuing.").font(.headline)
      ScrollView {
        VStack(alignment: .leading) {
          ForEach(Array(diagnostics.prefix(100).enumerated()), id: \.offset) { _, item in
            HStack {
              if let id = item.profileID,
                let profile = frozen?.workspace.profiles.first(where: { $0.id == id })
              {
                sourceLink(profileID: id, line: item.diagnostic.line, name: profile.name)
              } else {
                Text("System file")
              }
              if let line = item.diagnostic.line { Text("Line \(line):") }
              Text(diagnosticText(item.diagnostic.code, system: item.profileID == nil))
            }
          }
          if diagnostics.count > 100 { Text("Only the first 100 diagnostics are shown.") }
        }
      }
    case .plan:
      Text("The planned result exceeds a limit or cannot be safely composed.")
    }
  }
}

/// Local app-data recovery is separate from the system transaction recovery workflow.
private struct WorkspaceRecoveryView: View {
  let editor: ProfileWorkspaceModel
  let recovered: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selected: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Review previous workspace").font(.title2)
      Text(
        "Restoring replaces local drafts with this previous saved workspace. The damaged file is preserved in the workspace folder."
      )
      Text(
        "This does not change the system file or resolve an interrupted apply. Previously saved apply records are retained and must be checked against current system state."
      )
      if let candidate = editor.persisted.recoveryCandidate {
        Text("Saved generation: \(candidate.generation)")
        HStack {
          List(candidate.draft.profiles, selection: $selected) { profile in
            VStack(alignment: .leading) {
              Text(verbatim: profile.name)
              Text(profile.isEnabled ? "Desired active" : "Desired inactive").font(.caption)
            }.tag(profile.id)
          }
          if let profile = candidate.draft.profiles.first(where: { $0.id == selected }) {
            NativeProfileEditor(source: profile.source, isEditable: false, jump: nil) { _ in
              profile.source
            }.id(profile.id)
          } else {
            Text("Select a profile to inspect its saved text.")
              .frame(maxWidth: .infinity)
          }
        }.frame(minHeight: 240)
        Text(
          "Folders: \(candidate.draft.folders.count), trashed profiles: \(candidate.draft.trash.count)"
        )
        if candidate.pendingApply != nil {
          Text(
            "The previous workspace contains an interrupted apply. System recovery will still be required."
          )
        }
      }
      if editor.recoveryFailed {
        Text(
          "The previous workspace could not be restored. Data has been preserved. The file may have changed; close and reopen the app before trying again."
        )
        .foregroundStyle(.red)
        .accessibilityIdentifier("workspaceRecoveryFailure")
      }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if editor.isRecovering { ProgressView().controlSize(.small) }
        Button("Restore previous workspace") {
          Task { if await editor.recoverPrevious() { recovered() } }
        }
        .disabled(!editor.canRecoverPrevious || editor.recoveryFailed)
        .accessibilityIdentifier("restorePreviousWorkspace")
      }
      .disabled(editor.isRecovering)
    }
    .padding(24)
    .frame(width: 800, height: 540)
    .interactiveDismissDisabled(editor.isRecovering)
  }
}

private func workspaceRecoveryText(_ reason: WorkspaceRecoveryReason?) -> String {
  switch reason {
  case .corruptSnapshot:
    String(
      localized:
        "The saved workspace is damaged or missing. A valid previous save can be reviewed when available."
    )
  case .unsupportedSchema:
    String(
      localized:
        "This workspace was saved in an unsupported format. Open it with a compatible version of MacHosts."
    )
  case .unsafeOrUnreadableFile:
    String(
      localized:
        "The workspace file cannot be safely read. Check its access and file type before reopening the app."
    )
  case .interruptedCommit:
    String(
      localized:
        "A workspace save was interrupted. Close and reopen the app to check the saved data.")
  case .externalChange:
    String(
      localized:
        "The workspace changed outside this app. Preserve any unsaved text before closing and reopening the app."
    )
  case .migrationFailed:
    String(
      localized: "The workspace format could not be migrated. Its original data has been preserved."
    )
  case nil:
    String(localized: "The workspace is unavailable for editing.")
  }
}
