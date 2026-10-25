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
    WindowGroup("MacHosts") {
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
      CommandGroup(replacing: .newItem) {
        Button("New profile") { model.newProfile() }
          .keyboardShortcut("n")
          .disabled(model.editor?.isReadOnly != false)
        Button("Save drafts") { Task { _ = await model.editor?.flush() } }
          .keyboardShortcut("s")
      }
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
  var selection: UUID?
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

  func newProfile() {
    selection = editor?.create(name: String(localized: "New profile"))
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
      return try await WorkspaceStore.open(directory: directory)
    }
  }
#endif
