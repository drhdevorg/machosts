import AppKit
import Darwin
import HostsServices
import SwiftUI

@main
@MainActor
struct MacHostsApp: App {
  @State private var model = AppModel()

  init() {
    guard geteuid() != 0 else { exit(64) }
  }

  var body: some Scene {
    WindowGroup("MacHosts") {
      NavigationSplitView {
        List {
          Label("Profiles", systemImage: "doc.text")
        }
        .navigationTitle("MacHosts")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
      } detail: {
        ContentUnavailableView {
          Label("Your hosts profiles", systemImage: "network")
        } description: {
          Text("Profile management is being prepared.")
          if SystemApplyStatus.availability == .unavailable {
            Text("System changes are not available in this build.")
              .accessibilityIdentifier("systemApplyUnavailable")
          }
          SystemObservationView(
            model: model.system, refresh: model.refresh, restart: model.restartObservation)
        }
      }
      .task { model.start() }
      .onReceive(
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
      ) { _ in
        model.refresh()
      }
      .frame(minWidth: 640, minHeight: 400)
    }
    .defaultSize(width: 900, height: 600)
  }
}

/// One lifetime per app, shared by all windows. Closing a window does not cancel
/// observation or release the workspace's process lock.
@MainActor @Observable
private final class AppModel {
  let system = SystemObservationModel()
  private var store: WorkspaceStore?
  private var started = false
  private var openingWorkspace = false
  private var observationTask: Task<Void, Never>?

  func start() {
    guard !started else { return }
    started = true
    observationTask = Task { await system.run() }
    Task { await loadWorkspace() }
  }

  private func loadWorkspace() async {
    guard !openingWorkspace else { return }
    openingWorkspace = true
    defer { openingWorkspace = false }
    do {
      let opened = try await WorkspaceStore.openDefault()
      store = opened
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
    observationTask?.cancel()
    observationTask = Task { await system.run() }
  }
}

private struct SystemObservationView: View {
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
