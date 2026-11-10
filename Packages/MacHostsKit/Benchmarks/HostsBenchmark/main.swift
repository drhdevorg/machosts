import Foundation
import HostsCore
import HostsServices

// Measures the package-level work behind the provisional "100 profiles / 10,000 lines"
// budget. Synthetic data only: system text is an in-memory fixture, and the store uses a
// fresh private temporary directory. No hosts file, network or authorization is touched.
// Run with: swift run -c release HostsBenchmark

let profileCount = 100
let linesPerProfile = 100
let iterations = 15

func profileSource(_ index: Int) -> String {
  var lines = ["# Synthetic benchmark profile \(index)"]
  for line in 1..<linesPerProfile {
    let address = "198.51.\(index % 256).\(line % 256)"
    let entry = "\(address) p\(index)-h\(line).test p\(index)-a\(line).test # entry \(line)"
    lines.append(line % 10 == 0 ? HostsSyntax.disabled + entry : entry)
  }
  return lines.joined(separator: "\n") + "\n"
}

let folders = (0..<10).map { ProfileFolder(name: "Folder \($0)") }
let workspace = Workspace(
  revision: 1,
  profiles: (0..<profileCount).map {
    Profile(
      name: "Profile \($0)", folderID: folders[$0 % folders.count].id, source: profileSource($0),
      isEnabled: true)
  }, folders: folders)
let system = Data(
  """
  ##
  # Host Database
  ##
  127.0.0.1\tlocalhost
  255.255.255.255\tbroadcasthost
  ::1             localhost

  """.utf8)
let largeSource = (0..<profileCount).map(profileSource).joined()

func median(_ name: String, _ body: () throws -> Void) rethrows -> Double {
  var samples: [Double] = []
  for _ in 0..<iterations {
    let start = ContinuousClock.now
    try body()
    let elapsed = ContinuousClock.now - start
    samples.append(
      Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
  }
  let result = samples.sorted()[samples.count / 2]
  print(name.padding(toLength: 44, withPad: " ", startingAt: 0), String(format: "%9.2f ms", result))
  return result
}

func medianAsync(_ name: String, _ body: () async throws -> Void) async rethrows -> Double {
  var samples: [Double] = []
  for _ in 0..<iterations {
    let start = ContinuousClock.now
    try await body()
    let elapsed = ContinuousClock.now - start
    samples.append(
      Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
  }
  let result = samples.sorted()[samples.count / 2]
  print(name.padding(toLength: 44, withPad: " ", startingAt: 0), String(format: "%9.2f ms", result))
  return result
}

let totalLines = workspace.profiles.reduce(0) { $0 + $1.source.split(separator: "\n").count }
let encodedBytes = try workspace.encoded().count
print("Dataset: \(workspace.profiles.count) enabled profiles, \(totalLines) lines,")
print(
  "         \(encodedBytes) workspace bytes; single editor source \(largeSource.utf8.count) bytes")
print("Median of \(iterations) runs:")

var results: [String: Double] = [:]
results["parse"] = median("Parse all profiles") {
  for profile in workspace.profiles {
    let document = HostsDocument.parse(Data(profile.source.utf8), context: .profile)
    precondition(document.diagnostics.isEmpty)
  }
}
results["encode"] = try median("Validate and encode workspace") { _ = try workspace.encoded() }
let encoded = try workspace.encoded()
results["decode"] = try median("Decode workspace JSON") {
  _ = try JSONDecoder().decode(Workspace.self, from: encoded)
}
results["plan"] = try median("Compose full apply plan (all enabled)") {
  _ = try ApplyPlan.prepare(workspace: workspace, system: system)
}
results["presentation"] = median("Editor presentation, one 10,000-line source") {
  _ = ProfileEditorPresentation.make(source: largeSource)
}
let search = ProfileSearch()
results["search"] = await medianAsync("Search, one match in every profile") {
  _ = await search.search("h50.test", in: workspace)
}
results["searchRare"] = await medianAsync("Search, match in one profile") {
  _ = await search.search("p42-a7.test", in: workspace)
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent(
  "machosts-bench-" + UUID().uuidString, isDirectory: true)
defer { try? FileManager.default.removeItem(at: root) }
var draft = workspace
do {
  // The store holds an exclusive lock until it is released at the end of this scope.
  let store = try await WorkspaceStore.open(directory: root)
  var generation: UInt64 = 0
  results["save"] = try await medianAsync("Durable private draft save") {
    draft.revision += 1
    generation = try await store.saveDraft(draft, expectedGeneration: generation).generation
  }
}
results["open"] = try await medianAsync("Open private store with saved draft") {
  let reopened = try await WorkspaceStore.open(directory: root)
  let reopenedDraft = await reopened.state().snapshot?.draft
  precondition(reopenedDraft == draft)
}
results["model"] = try await medianAsync("Open store and workspace model") {
  let reopened = try await WorkspaceStore.open(directory: root)
  let model = try await ProfileWorkspaceModel.open(store: reopened)
  precondition(model.workspace == draft)
}

let launchPath = ["model", "presentation"].compactMap { results[$0] }.reduce(0, +)
print(String(format: "Package share of first-window path: %.2f ms (budget 2,000 ms)", launchPath))
