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
  @AppStorage(AppSettings.showsMenuBarExtra) private var showsMenuBarExtra = true

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
      CommandGroup(after: .help) {
        DiagnosticsCommand()
      }
    }

    // The menu bar shares the app model; closing every window keeps it available.
    MenuBarExtra("MacHosts", systemImage: "network", isInserted: $showsMenuBarExtra) {
      MenuBarContent(model: model)
    }
    .menuBarExtraStyle(.menu)

    Window("Diagnostics", id: "diagnostics") {
      DiagnosticsView(model: model)
    }
    .defaultSize(width: 640, height: 560)

    Settings {
      SettingsView(model: model)
    }
  }
}

private struct DiagnosticsCommand: View {
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Button("Diagnostics") { openWindow(id: "diagnostics") }
  }
}

/// UserDefaults keys for small UI preferences only; workspace data never lives here.
enum AppSettings {
  static let showsMenuBarExtra = "showsMenuBarExtra"
  static let refreshRemoteOnLaunch = "refreshRemoteOnLaunch"
  /// Hours between in-process refreshes; 0 disables interval refresh.
  static let remoteRefreshHours = "remoteRefreshHours"
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
  let newRemoteProfile: () -> Void
  let refreshRemote: () -> Void
  let canRefreshRemote: Bool
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
      Button("New remote profile…") { actions?.newRemoteProfile() }
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
      Button("Refresh remote profiles") { actions?.refreshRemote() }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(actions?.canRefreshRemote != true)
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
  struct WindowRequest: Equatable {
    enum Kind: Equatable {
      case preview, addRemote, status
      case select(UUID)
    }
    let id = UUID()
    let kind: Kind
  }

  var editor: ProfileWorkspaceModel?
  let system = SystemObservationModel()
  let remote = RemoteRefreshModel()
  /// Set by the menu bar; the first workspace window that sees it consumes it.
  var windowRequest: WindowRequest?
  private var scheduleTask: Task<Void, Never>?
  #if DEBUG
    let isPrivateTest = ProcessInfo.processInfo.arguments.contains("--ui-testing-local-workspace")
  #elseif MACHOSTS_MEASUREMENT
    // Only a separately compiled measurement build accepts this; shipping Release does not.
    let isPrivateTest = ProcessInfo.processInfo.arguments.contains("--measurement-workspace")
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
    var observes = !isPrivateTest
    #if MACHOSTS_MEASUREMENT
      // Read-only observation of the real hosts file, for idle measurements with it running.
      observes = observes || LaunchMeasurement.observesSystem
    #endif
    if observes { observationTask = Task { await system.run() } }
    Task { await loadWorkspace() }
  }

  private func loadWorkspace() async {
    guard !openingWorkspace else { return }
    openingWorkspace = true
    defer { openingWorkspace = false }
    do {
      let opened: WorkspaceStore
      #if DEBUG || MACHOSTS_MEASUREMENT
        if isPrivateTest {
          opened = try await PrivateUITestWorkspace.open()
        } else {
          opened = try await WorkspaceStore.openDefault()
        }
      #else
        opened = try await WorkspaceStore.openDefault()
      #endif
      store = opened
      let editor = try await ProfileWorkspaceModel.open(store: opened)
      self.editor = editor
      #if MACHOSTS_MEASUREMENT
        if isPrivateTest {
          LaunchMeasurement.reportAfterNextRender(editor: editor)
          if LaunchMeasurement.measuresInteraction {
            Task { await LaunchMeasurement.measureInteraction(app: self, editor: editor) }
          }
          if LaunchMeasurement.auditsContrast { LaunchMeasurement.auditContrast() }
          if LaunchMeasurement.measuresMenu {
            Task { await LaunchMeasurement.measureMenu() }
          }
          if LaunchMeasurement.auditsAccessibility {
            Task { await LaunchMeasurement.auditAccessibility(app: self, editor: editor) }
          }
        }
      #endif
      system.updateWorkspace(await opened.state())
      if !isPrivateTest {
        if UserDefaults.standard.bool(forKey: AppSettings.refreshRemoteOnLaunch) {
          remote.refreshAll(editor: editor)
        }
        updateRemoteSchedule()
      }
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

  /// Restarts the in-process interval refresh after a settings change. No timer runs
  /// when interval refresh is off or no workspace is open.
  func updateRemoteSchedule() {
    scheduleTask?.cancel()
    scheduleTask = nil
    let hours = UserDefaults.standard.integer(forKey: AppSettings.remoteRefreshHours)
    guard hours > 0, let editor, !isPrivateTest else { return }
    scheduleTask = Task { [remote] in
      await remote.runSchedule(editor: editor, interval: TimeInterval(hours) * 3_600)
    }
  }

  func request(_ kind: WindowRequest.Kind) {
    windowRequest = WindowRequest(kind: kind)
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

#if DEBUG || MACHOSTS_MEASUREMENT
  /// An explicit UI-test mode with a fresh private directory and no system observation.
  /// No supplied path, authorization adapter or simulated apply is accepted.
  private actor PrivateUITestWorkspace {
    static func open() async throws -> WorkspaceStore {
      #if MACHOSTS_MEASUREMENT
        return try await LaunchMeasurement.openSeededWorkspace()
      #else
        return try await openUITestWorkspace()
      #endif
    }

    private static func openUITestWorkspace() async throws -> WorkspaceStore {
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

#if MACHOSTS_MEASUREMENT
  /// Launch measurement for the separately compiled `MACHOSTS_MEASUREMENT` Release build.
  /// The workspace is a fresh private temporary directory seeded with the synthetic
  /// 100-profile/10,000-line dataset of `HostsBenchmark` (or left empty with
  /// `--measurement-empty-workspace`). Nothing is applied and the system file is not observed.
  enum LaunchMeasurement {
    static func openSeededWorkspace() async throws -> WorkspaceStore {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "machosts-measure-" + UUID().uuidString, isDirectory: true)
      let store = try await WorkspaceStore.open(directory: directory)
      if !ProcessInfo.processInfo.arguments.contains("--measurement-empty-workspace") {
        _ = try await store.saveDraft(dataset(), expectedGeneration: 0)
      }
      return store
    }

    static let observesSystem = ProcessInfo.processInfo.arguments.contains(
      "--measurement-observe-system")
    static let measuresInteraction = ProcessInfo.processInfo.arguments.contains(
      "--measurement-interaction")
    static let largeProfileName = "Measurement large profile"
    static let largeProfileLines = 10_000

    /// Mirrors `HostsBenchmark`: 100 enabled profiles × 100 lines in ten folders. The
    /// interaction run adds one enabled 10,000-line profile as the editing worst case.
    private static func dataset() -> Workspace {
      let folders = (0..<10).map { ProfileFolder(name: "Folder \($0)") }
      let profiles = (0..<100).map { index in
        var lines = ["# Synthetic benchmark profile \(index)"]
        for line in 1..<100 {
          let entry =
            "198.51.\(index % 256).\(line % 256) p\(index)-h\(line).test p\(index)-a\(line).test"
            + " # entry \(line)"
          lines.append(line % 10 == 0 ? HostsSyntax.disabled + entry : entry)
        }
        return Profile(
          name: "Profile \(index)", folderID: folders[index % folders.count].id,
          source: lines.joined(separator: "\n") + "\n", isEnabled: true)
      }
      var all = profiles
      if measuresInteraction {
        let lines = (0..<largeProfileLines).map { line in
          "203.0.\(line / 256 % 256).\(line % 256) large-\(line).test # line \(line)"
        }
        all.append(
          Profile(
            name: largeProfileName, source: lines.joined(separator: "\n") + "\n",
            isEnabled: true))
      }
      return Workspace(revision: 1, profiles: all, folders: folders)
    }

    /// Types and scrolls in the large profile's real `NSTextView` and reports per-event
    /// synchronous handling time plus the longest main-thread stalls, measured by a
    /// background timer that enqueues a main-queue block every 5 ms. Writes only to the
    /// private temporary workspace through the normal edit and autosave path.
    static func measureInteraction(app: AppModel, editor: ProfileWorkspaceModel) async {
      try? await Task.sleep(for: .seconds(2))
      guard let profile = editor.workspace.profiles.first(where: { $0.name == largeProfileName })
      else { return report("interaction-error=no-large-profile") }
      app.request(.select(profile.id))
      let length = (profile.source as NSString).length
      var found: NSTextView?
      for _ in 0..<400 {
        found =
          NSApp.windows.lazy.compactMap { profileTextView(in: $0.contentView, length: length) }
          .first
        if found != nil { break }
        try? await Task.sleep(for: .milliseconds(25))
      }
      guard let text = found, let window = text.window, let scroll = text.enclosingScrollView
      else { return report("interaction-error=no-editor") }
      window.makeFirstResponder(text)
      try? await Task.sleep(for: .seconds(1))  // Let the initial styling pass finish.

      let monitor = MainThreadStallMonitor()
      // Typing: 15 bursts of 20 characters at 30 characters per second, each followed by a
      // 500 ms pause so the debounced styling and autosave run between bursts.
      let middle = (profile.source as NSString).lineRange(
        for: NSRange(location: length / 2, length: 0))
      text.setSelectedRange(NSRange(location: NSMaxRange(middle) - 1, length: 0))
      text.scrollRangeToVisible(text.selectedRange())
      _ = monitor.drain()
      var typing: [Double] = []
      for burst in 0..<15 {
        for index in 0..<20 {
          let start = DispatchTime.now().uptimeNanoseconds
          let character =
            index == 19 ? " " : String(UnicodeScalar(UInt8(97 + (burst + index) % 26)))
          text.insertText(character, replacementRange: text.selectedRange())
          window.displayIfNeeded()
          typing.append(milliseconds(since: start))
          try? await Task.sleep(for: .milliseconds(33))
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
      let typingStalls = monitor.drain()
      let saved = await editor.flush()
      let typed = editor.workspace.profiles.first { $0.id == profile.id }?.source
      report(
        "interaction-typing " + summary(typing) + " " + stallSummary(typingStalls)
          + " saved=\(saved) accepted=\(typed.map { ($0 as NSString).length - length } ?? -1)")

      // Scrolling: the whole document top to bottom in 120-point steps at about 120 Hz,
      // then 60 deterministic jumps to distant lines.
      let clip = scroll.contentView
      let height = text.frame.height - clip.bounds.height
      var scrolling: [Double] = []
      _ = monitor.drain()
      var y: CGFloat = 0
      while y <= height {
        let start = DispatchTime.now().uptimeNanoseconds
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        window.displayIfNeeded()
        scrolling.append(milliseconds(since: start))
        y += 120
        try? await Task.sleep(for: .milliseconds(8))
      }
      let scrollStalls = monitor.drain()
      var jumps: [Double] = []
      let current = text.string as NSString
      for step in 0..<60 {
        let location = (step * 7_919 % 997) * current.length / 997
        let start = DispatchTime.now().uptimeNanoseconds
        text.scrollRangeToVisible(NSRange(location: location, length: 0))
        window.displayIfNeeded()
        jumps.append(milliseconds(since: start))
        try? await Task.sleep(for: .milliseconds(50))
      }
      let jumpStalls = monitor.drain()
      monitor.stop()
      report(
        "interaction-scroll frames=\(scrolling.count) " + summary(scrolling) + " "
          + stallSummary(scrollStalls))
      report("interaction-jump " + summary(jumps) + " " + stallSummary(jumpStalls))
      report("interaction-done")
    }

    static let auditsAccessibility = ProcessInfo.processInfo.arguments.contains(
      "--measurement-accessibility")

    /// Walks the app's own accessibility tree (the tree VoiceOver reads; no Accessibility
    /// permission is needed in-process) for the main window and the preview, add-remote and
    /// status sheets, and reports interactive elements without a spoken name. Each sheet is
    /// dismissed with a synthesized Escape key, which must close it and return key focus to
    /// the main window.
    static func auditAccessibility(app: AppModel, editor: ProfileWorkspaceModel) async {
      try? await Task.sleep(for: .seconds(2))
      NSApp.activate()
      if let first = editor.workspace.profiles.first { app.request(.select(first.id)) }
      try? await Task.sleep(for: .seconds(1))
      guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
      else { return report("accessibility-error=no-window") }
      await auditTree(of: window, surface: "main")
      for (name, kind) in [
        ("preview", AppModel.WindowRequest.Kind.preview), ("add-remote", .addRemote),
        ("status", .status),
      ] {
        func responder() -> String {
          window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        }
        // Start from the editor, as when a shortcut opens the sheet while typing.
        if let source = sourceTextView(in: window.contentView) { window.makeFirstResponder(source) }
        try? await Task.sleep(for: .milliseconds(200))
        let before = responder()
        app.request(kind)
        var sheet: NSWindow?
        for _ in 0..<200 {
          sheet = window.attachedSheet
          if sheet != nil { break }
          try? await Task.sleep(for: .milliseconds(25))
        }
        guard let sheet else {
          report("accessibility-surface=\(name) error=no-sheet")
          continue
        }
        try? await Task.sleep(for: .seconds(1))
        await auditTree(of: sheet, surface: name)
        let escape = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
        if let escape { NSApp.sendEvent(escape) }
        var closed = false
        for _ in 0..<200 {
          closed = window.attachedSheet == nil
          if closed { break }
          try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(300))
        report(
          "accessibility-surface=\(name) escape-closes=\(closed)"
            + " main-key=\(window.isKeyWindow) responder-before=\(before) responder-after=\(responder())"
        )
        if !closed { sheet.sheetParent?.endSheet(sheet) }
      }
      report("accessibility-done")
    }

    static let auditsContrast = ProcessInfo.processInfo.arguments.contains(
      "--measurement-contrast")

    /// Reports WCAG contrast ratios of the editor's text colors against the backgrounds
    /// they are drawn on, resolved in the light and dark appearance. Translucent colors are
    /// composited over their background first.
    static func auditContrast() {
      typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
      func composite(_ color: NSColor, over background: RGB) -> RGB {
        let c = color.usingColorSpace(.sRGB) ?? .black
        let a = c.alphaComponent
        return (
          c.redComponent * a + background.r * (1 - a),
          c.greenComponent * a + background.g * (1 - a),
          c.blueComponent * a + background.b * (1 - a)
        )
      }
      func luminance(_ c: RGB) -> CGFloat {
        func channel(_ v: CGFloat) -> CGFloat {
          v <= 0.040_45 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
      }
      func ratio(_ a: RGB, _ b: RGB) -> CGFloat {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
      }
      let styles: [(String, ProfileEditorPresentation.Style)] = [
        ("address", .address), ("hostname", .hostname), ("comment", .comment),
        ("disabled", .disabled), ("managed", .managed), ("invalid", .invalid),
      ]
      for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
          MainActor.assumeIsolated {
            let opaque: RGB = name == "light" ? (1, 1, 1) : (0, 0, 0)
            let text = composite(.textBackgroundColor, over: opaque)
            let managed = composite(EditorPalette.managedBackground, over: text)
            let window = composite(.windowBackgroundColor, over: opaque)
            var lowest = CGFloat.infinity
            func record(_ label: String, _ value: CGFloat) {
              lowest = min(lowest, value)
              report(String(format: "contrast appearance=%@ %@ ratio=%.2f", name, label, value))
            }
            for (style, value) in styles {
              let color = EditorPalette.color(for: value)
              record("\(style)-on-text", ratio(composite(color, over: text), text))
              record("\(style)-on-managed", ratio(composite(color, over: managed), managed))
            }
            record(
              "line-number-on-ruler",
              ratio(composite(EditorPalette.lineNumber, over: window), window))
            report(String(format: "contrast appearance=%@ lowest=%.2f", name, lowest))
          }
        }
      }
      report("contrast-done")
    }

    static let measuresMenu = ProcessInfo.processInfo.arguments.contains("--measurement-menu")

    /// Opens the menu bar extra's menu eleven times through its status item button and
    /// reports the time from the click until the menu's tracking loop first runs, which is
    /// after the menu window is ordered in. Each menu stays open for 200 ms and must end
    /// tracking before the next opening. The first opening is cold; the rest are warm.
    static func measureMenu() async {
      try? await Task.sleep(for: .seconds(2))
      guard let button = statusItemButton() else { return report("menu-error=no-status-item") }
      final class Sample {
        var start: UInt64 = 0
        var began: Double = -1
        var opened: Double = -1
        var ended = false
        var items = -1
      }
      var opens: [Double] = []
      var failures = 0
      for run in 0..<11 {
        let sample = Sample()
        let center = NotificationCenter.default
        let begin = center.addObserver(
          forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { note in
          // Posted on the main thread by the menu tracking that `performClick` starts.
          nonisolated(unsafe) let tracked = note.object as? NSMenu
          MainActor.assumeIsolated {
            guard sample.began < 0, let menu = tracked else { return }
            sample.began = milliseconds(since: sample.start)
            nonisolated(unsafe) let open = menu
            RunLoop.main.perform(inModes: [.eventTracking, .default]) {
              MainActor.assumeIsolated {
                sample.opened = milliseconds(since: sample.start)
                sample.items = open.numberOfItems
              }
            }
            let close = Timer(timeInterval: 0.2, repeats: false) { _ in
              MainActor.assumeIsolated { open.cancelTracking() }
            }
            RunLoop.main.add(close, forMode: .common)
          }
        }
        let end = center.addObserver(
          forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { sample.ended = true } }
        sample.start = DispatchTime.now().uptimeNanoseconds
        button.performClick(nil)
        for _ in 0..<300 where !sample.ended { try? await Task.sleep(for: .milliseconds(10)) }
        center.removeObserver(begin)
        center.removeObserver(end)
        report(
          String(
            format: "menu-open run=%d began-ms=%.1f opened-ms=%.1f items=%d ended=%d", run,
            sample.began, sample.opened, sample.items, sample.ended ? 1 : 0))
        if sample.opened < 0 { failures += 1 }
        if run > 0, sample.opened >= 0 { opens.append(sample.opened) }
        try? await Task.sleep(for: .seconds(1))
      }
      report("menu-warm " + summary(opens) + " failed-openings=\(failures)")
      report("menu-done")
    }

    private static func statusItemButton() -> NSStatusBarButton? {
      func find(_ view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap { find($0) }.first
      }
      return NSApp.windows.lazy.compactMap { find($0.contentView) }.first
    }

    private static let interactiveRoles: Set<String> = [
      "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
      "AXTextArea", "AXSlider", "AXComboBox", "AXDisclosureTriangle", "AXLink", "AXIncrementor",
      "AXRow",
    ]

    private static let systemSubroles: Set<String> = [
      "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
      "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage",
    ]

    private static func hasDescendantText(_ element: AXUIElement, depth: Int = 0) -> Bool {
      guard depth < 4 else { return false }
      for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        let texts = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap {
          attribute(child, $0) as? String
        }
        if texts.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
          return true
        }
        if hasDescendantText(child, depth: depth + 1) { return true }
      }
      return false
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
      var value: CFTypeRef?
      return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        ? value : nil
    }

    /// Walks the tree through the public AX client API against this process, which is what
    /// VoiceOver reads. The first query enables SwiftUI's accessibility tree, so the walk
    /// repeats until the element count stops changing.
    private static func auditTree(of window: NSWindow, surface: String) async {
      let application = AXUIElementCreateApplication(getpid())
      var previous = -1
      var stable = 0
      for _ in 0..<20 where stable < 2 {
        let count = walk(application).total
        stable = count == previous ? stable + 1 : 0
        previous = count
        try? await Task.sleep(for: .milliseconds(500))
      }
      let result = walk(application)
      let roleList = result.roles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        .joined(separator: ",")
      report(
        "accessibility-surface=\(surface) elements=\(result.total)"
          + " interactive=\(result.interactive) unnamed=\(result.unnamed.count) roles=\(roleList)")
      for item in result.unnamed { report("accessibility-unnamed surface=\(surface) \(item)") }
      for item in result.named { report("accessibility-name surface=\(surface) \(item)") }
    }

    private static func walk(_ application: AXUIElement) -> (
      total: Int, interactive: Int, unnamed: [String], roles: [String: Int], named: [String]
    ) {
      var total = 0
      var interactive = 0
      var unnamed: [String] = []
      var roles: [String: Int] = [:]
      var named: [String] = []
      func visit(_ element: AXUIElement, depth: Int, path: String) {
        guard depth < 80 else { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
        if role == kAXMenuBarRole as String { return }
        total += 1
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        // The first-launch summary of foreign system file entries is spoken text.
        if attribute(element, kAXIdentifierAttribute) as? String == "foreignEntrySummary" {
          let value = attribute(element, kAXValueAttribute) as? String ?? "<no value>"
          named.append("\(role)/foreignEntrySummary \"\(value)\"")
        }
        if interactiveRoles.contains(role) {
          interactive += 1
          roles[role, default: 0] += 1
          let names = [
            kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute,
          ].compactMap { attribute(element, $0) as? String }
          let hasTitleElement = attribute(element, kAXTitleUIElementAttribute) != nil
          // Rows are named by their cell contents; buttons may carry their name in a child.
          // Window and scroll bar controls are named by the system through their subrole.
          if role != "AXRow", !systemSubroles.contains(subrole) {
            let spoken =
              names.first { !$0.isEmpty } ?? (hasTitleElement ? "<title element>" : "<child text>")
            named.append("\(role)/\(subrole) \"\(spoken)\"")
          }
          if !hasTitleElement, !systemSubroles.contains(subrole), !hasDescendantText(element),
            names.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty })
          {
            let identifier = attribute(element, kAXIdentifierAttribute) as? String ?? "-"
            let help = attribute(element, kAXHelpAttribute) as? String ?? ""
            unnamed.append("\(role)/\(subrole)[\(identifier)] help=\"\(help)\" in \(path)")
          }
        }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children {
          visit(child, depth: depth + 1, path: depth < 6 ? path + ">" + role : path)
        }
      }
      visit(application, depth: 0, path: "")
      return (total, interactive, unnamed, roles, named)
    }

    private static func sourceTextView(in view: NSView?) -> NSTextView? {
      guard let view else { return nil }
      if let text = view as? NSTextView, text.accessibilityIdentifier() == "profileSource" {
        return text
      }
      return view.subviews.lazy.compactMap { sourceTextView(in: $0) }.first
    }

    private static func profileTextView(in view: NSView?, length: Int) -> NSTextView? {
      guard let view else { return nil }
      if let text = view as? NSTextView, text.accessibilityIdentifier() == "profileSource",
        (text.string as NSString).length == length
      {
        return text
      }
      for child in view.subviews {
        if let text = profileTextView(in: child, length: length) { return text }
      }
      return nil
    }

    nonisolated private static func milliseconds(since start: UInt64) -> Double {
      Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func summary(_ values: [Double]) -> String {
      let sorted = values.sorted()
      guard !sorted.isEmpty else { return "events=0" }
      func percentile(_ p: Double) -> Double {
        sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
      }
      return String(
        format: "events=%d p50-ms=%.2f p95-ms=%.2f max-ms=%.2f", sorted.count, percentile(0.5),
        percentile(0.95), sorted.last!)
    }

    private static func stallSummary(_ latencies: [Double]) -> String {
      String(
        format: "main-max-stall-ms=%.1f stalls-over-50ms=%d stalls-over-100ms=%d",
        latencies.max() ?? 0, latencies.filter { $0 > 50 }.count,
        latencies.filter { $0 > 100 }.count)
    }

    nonisolated private static func report(_ text: String) {
      FileHandle.standardError.write(Data("measurement \(text) pid=\(getpid())\n".utf8))
    }

    /// Records how long main-queue blocks enqueued every 5 ms from a background queue wait.
    nonisolated private final class MainThreadStallMonitor: @unchecked Sendable {
      private let lock = NSLock()
      private var latencies: [Double] = []
      private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))

      init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { @Sendable [weak self] in
          let posted = DispatchTime.now().uptimeNanoseconds
          DispatchQueue.main.async { self?.record(LaunchMeasurement.milliseconds(since: posted)) }
        }
        timer.resume()
      }

      private func record(_ value: Double) {
        lock.lock()
        latencies.append(value)
        lock.unlock()
      }

      func drain() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        let values = latencies
        latencies.removeAll(keepingCapacity: true)
        return values
      }

      func stop() { timer.cancel() }
    }

    /// Prints the time from process start (kernel start time, so exec and dyld are included)
    /// until the main run loop turns after the loaded workspace was published to SwiftUI.
    static func reportAfterNextRender(editor: ProfileWorkspaceModel) {
      let profiles = editor.workspace.profiles.count
      DispatchQueue.main.async {
        DispatchQueue.main.async {
          let line = String(
            format: "measurement first-window-ready-ms=%.1f profiles=%d pid=%d\n",
            millisecondsSinceProcessStart(), profiles, getpid())
          FileHandle.standardError.write(Data(line.utf8))
        }
      }
    }

    private static func millisecondsSinceProcessStart() -> Double {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
      guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return -1 }
      let start = info.kp_proc.p_un.__p_starttime
      var now = timeval()
      gettimeofday(&now, nil)
      return Double(now.tv_sec - start.tv_sec) * 1_000
        + Double(Int(now.tv_usec) - Int(start.tv_usec)) / 1_000
    }
  }
#endif
