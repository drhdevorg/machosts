import AppKit
import Darwin
import HostsCore
import HostsServices
import SwiftUI

@main
@MainActor
struct MacHostsApp: App {
  @State private var model = AppModel()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  init() {
    guard geteuid() != 0 else { exit(64) }
  }

  var body: some Scene {
    WindowGroup("MacHosts", id: "workspace") {
      ProfileWorkspaceView(model: model)
        .task {
          delegate.flush = { await model.editor?.flush() ?? true }
          model.start()
        }
        .onReceive(
          NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        ) { _ in model.refresh() }
        .frame(minWidth: 760, minHeight: 500)
    }
    .defaultSize(width: 1050, height: 740)
    .commands {
      WorkspaceCommands()
    }
  }
}

/// Commands follow the active window and are unavailable while its sheets are open.
struct WorkspaceCommandActions {
  let canEdit: Bool
  let hasProfile: Bool
  let canReplace: Bool
  let canManageProfile: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let duplicate: () -> Void
  let delete: () -> Void
  let move: (Int) -> Void
  let newProfile: () -> Void
  let save: () -> Void
  let search: () -> Void
  let find: (Bool) -> Void
  let preview: () -> Void
  let folders: () -> Void
  let trash: () -> Void
  let systemStatus: () -> Void
  let exchange: () -> Void
}

private struct WorkspaceCommandKey: FocusedValueKey {
  typealias Value = WorkspaceCommandActions
}

extension FocusedValues {
  var workspaceCommands: WorkspaceCommandActions? {
    get { self[WorkspaceCommandKey.self] }
    set { self[WorkspaceCommandKey.self] = newValue }
  }
}

private struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceCommands) private var actions
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New window") { openWindow(id: "workspace") }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Button("New profile") { actions?.newProfile() }
        .keyboardShortcut("n")
        .disabled(actions?.canEdit != true)
      Button("Import / Export…") { actions?.exchange() }
        .disabled(actions == nil)
      Button("Save drafts") { actions?.save() }
        .keyboardShortcut("s")
        .disabled(actions?.canEdit != true)
    }
    CommandMenu("Find") {
      Button("Find in profile…") { actions?.find(false) }
        .keyboardShortcut("f")
        .disabled(actions?.hasProfile != true)
      Button("Replace in profile…") { actions?.find(true) }
        .keyboardShortcut("f", modifiers: [.command, .option])
        .disabled(actions?.canReplace != true)
      Button("Search all profiles") { actions?.search() }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(actions == nil)
    }
    CommandMenu("Profiles") {
      Button("Duplicate as local profile") { actions?.duplicate() }
        .disabled(actions?.canManageProfile != true)
      Button("Move up") { actions?.move(-1) }
        .disabled(actions?.canMoveUp != true)
      Button("Move down") { actions?.move(1) }
        .disabled(actions?.canMoveDown != true)
      Button("Move to trash") { actions?.delete() }
        .disabled(actions?.canManageProfile != true)
      Divider()
      Button("Preview changes") { actions?.preview() }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(actions?.canEdit != true)
      Button("Folders") { actions?.folders() }
        .disabled(actions?.canEdit != true)
      Button("Trash") { actions?.trash() }
        .disabled(actions == nil)
      Divider()
      Button("System file status") { actions?.systemStatus() }
        .disabled(actions == nil)
    }
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  var flush: (() async -> Bool)?
  private var terminating = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating else { return .terminateLater }
    guard let flush else { return .terminateNow }
    terminating = true
    Task {
      let saved = await flush()
      if !saved {
        let alert = NSAlert()
        alert.messageText = String(localized: "Drafts could not be saved.")
        alert.informativeText = String(
          localized: "The app stays open so you can preserve your changes and retry saving.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
      }
      terminating = false
      sender.reply(toApplicationShouldTerminate: saved)
    }
    return .terminateLater
  }
}

/// One lifetime per app, shared by all windows. Closing a window does not cancel
/// observation or release the workspace's process lock.
@MainActor @Observable
final class AppModel {
  var editor: ProfileWorkspaceModel?
  let system = SystemObservationModel()
  #if DEBUG
    let isPrivateTest = ProcessInfo.processInfo.arguments.contains("--ui-testing-local-workspace")
  #else
    let isPrivateTest = false
  #endif
  private var store: WorkspaceStore?
  private var started = false
  private var openingWorkspace = false
  private var observationTask: Task<Void, Never>?

  func start() {
    guard !started else { return }
    started = true
    if !isPrivateTest { observationTask = Task { await system.run() } }
    Task { await loadWorkspace() }
  }

  private func loadWorkspace() async {
    guard !openingWorkspace else { return }
    openingWorkspace = true
    defer { openingWorkspace = false }
    do {
      let opened: WorkspaceStore
      #if DEBUG
        if isPrivateTest {
          opened = try await PrivateUITestWorkspace.open()
        } else {
          opened = try await WorkspaceStore.openDefault()
        }
      #else
        opened = try await WorkspaceStore.openDefault()
      #endif
      store = opened
      editor = try await ProfileWorkspaceModel.open(store: opened)
      system.updateWorkspace(await opened.state())
    } catch {
      system.updateWorkspace(nil)
    }
  }

  func refresh() {
    Task {
      if let store {
        system.updateWorkspace(await store.state())
      } else {
        await loadWorkspace()
      }
      await system.refresh()
    }
  }

  func restartObservation() {
    guard !isPrivateTest else { return }
    observationTask?.cancel()
    observationTask = Task { await system.run() }
  }
}

struct SystemObservationView: View {
  let model: SystemObservationModel
  let refresh: () -> Void
  let restart: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Label("System file status", systemImage: "eye")
      statusText.accessibilityIdentifier("systemObservationStatus")
      if model.workspaceUnavailable || model.workspaceReadOnlyReason != nil {
        Text("Workspace could not be opened for normal use. Its data has been preserved.")
      }
      if case .unreadable(let failure) = model.observation {
        failureText(failure)
      }
      if let pending = model.pendingFileState {
        pendingText(pending).accessibilityIdentifier("pendingApplyFileState")
        Text(
          "Matching file contents alone cannot establish whether the interrupted apply completed.")
        if SystemApplyStatus.availability == .unavailable {
          Text(
            "This build cannot check the system transaction records. The pending apply is preserved and further applies remain blocked."
          )
        }
      }
      if let contents = model.contents {
        Text("System file contents").font(.headline)
        Text("Read-only. The blue background marks the MacHosts managed block.")
          .font(.caption)
        if let source = contents.source {
          NativeProfileEditor(source: source, isSystem: true, isEditable: false, jump: nil) { _ in
            source
          }
          .frame(minHeight: 260)
        } else {
          Text("The file encoding is unsupported. Contents cannot be displayed without conversion.")
        }
        if !contents.diagnostics.isEmpty {
          Text("The system file has parser diagnostics. Applying changes may be blocked.")
            .foregroundStyle(.orange)
          ScrollView {
            VStack(alignment: .leading) {
              ForEach(Array(contents.diagnostics.prefix(20).enumerated()), id: \.offset) {
                _, diagnostic in
                HStack(alignment: .firstTextBaseline) {
                  if let line = diagnostic.line { Text("Line \(line):") }
                  Text(diagnosticText(diagnostic.code, system: true))
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 80)
          if contents.diagnostics.count > 20 { Text("Only the first 20 diagnostics are shown.") }
        }
      }
      HStack {
        Button("Check again", action: refresh)
        Button("Restart observation", action: restart)
      }
      Text("Observation does not change the system file or resolve an interrupted apply.")
        .font(.caption)
    }
    .padding(.top)
  }

  private func pendingText(_ state: PendingApplyFileState) -> Text {
    switch state {
    case .before: Text("The system file matches the state before the interrupted apply.")
    case .after: Text("The system file matches the intended result of the interrupted apply.")
    case .other: Text("The system file matches neither state of the interrupted apply.")
    case .unreadable: Text("The interrupted apply cannot be compared with a current file reading.")
    }
  }

  private var statusText: Text {
    switch model.status {
    case .confirmed: Text("System file matches the last verified apply.")
    case .externalChange: Text("System file changed externally.")
    case .recoveryRequired: Text("An interrupted apply requires recovery.")
    case .unconfirmed:
      if model.observation == nil {
        Text("System file has not been checked.")
      } else {
        Text("Current system state is unconfirmed.")
      }
    }
  }

  private func failureText(_ failure: SystemFileReadFailure) -> Text {
    switch failure {
    case .unavailable: Text("System file could not be read.")
    case .unsafeFile: Text("System file has an unsupported file type or link count.")
    case .tooLarge: Text("System file exceeds the read limit.")
    case .changedDuringRead: Text("System file changed while it was being read.")
    case .watchUnavailable:
      Text("File observation is unavailable. Restart observation to try again.")
    }
  }
}

#if DEBUG
  /// An explicit UI-test mode with a fresh private directory and no system observation.
  /// No supplied path, authorization adapter or simulated apply is accepted.
  private actor PrivateUITestWorkspace {
    static func open() async throws -> WorkspaceStore {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "machosts-ui-" + UUID().uuidString, isDirectory: true)
      if ProcessInfo.processInfo.arguments.contains("--ui-testing-damaged-workspace") {
        try await seedRecoveryCandidate(directory: directory)
        try Data("{truncated UI fixture".utf8).write(
          to: directory.appendingPathComponent("workspace.json"))
      }
      return try await WorkspaceStore.open(directory: directory)
    }

    private static func seedRecoveryCandidate(directory: URL) async throws {
      let store = try await WorkspaceStore.open(directory: directory)
      _ = try await store.saveDraft(
        Workspace(
          revision: 1,
          profiles: [
            Profile(name: "Recovered fixture", source: "192.0.2.23 recovery.example\n")
          ]), expectedGeneration: 0)
      _ = try await store.saveDraft(Workspace(revision: 2), expectedGeneration: 1)
    }
  }
#endif
