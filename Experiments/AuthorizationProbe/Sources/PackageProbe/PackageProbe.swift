import Darwin
import Foundation

/// Developer-only packager. Does not install, open the app, or request privileges.
@main
enum PackageProbe {
  enum Failure: Error {
    case invalidInvocation, missingBinary, artifactAlreadyExists
    case commandFailed(String, Int32)
  }

  static func main() {
    do { try package() } catch {
      FileHandle.standardError.write(Data("Packaging failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func package() throws {
    guard geteuid() != 0, CommandLine.arguments.count == 1 else {
      throw Failure.invalidInvocation
    }
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let binaries = try run(
      "/usr/bin/swift",
      [
        "build", "--build-system", "native", "--disable-sandbox", "-c", "release",
        "--show-bin-path",
      ],
      at: root
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    let output = root.appendingPathComponent("Output", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let app = output.appendingPathComponent("MacHostsAuthorizationProbe.app", isDirectory: true)
    // Refuse to overwrite an existing artifact; retain it for comparison.
    guard !FileManager.default.fileExists(atPath: app.path) else {
      throw Failure.artifactAlreadyExists
    }
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    for name in ["MacHostsAuthorizationProbe", "MacHostsProbeTool"] {
      let binary = URL(fileURLWithPath: binaries).appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: binary.path) else { throw Failure.missingBinary }
      let destination = macOS.appendingPathComponent(name)
      try FileManager.default.copyItem(at: binary, to: destination)
      _ = try run(
        "/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", destination.path],
        at: root)
    }
    let plist: [String: Any] = [
      "CFBundleIdentifier": "dev.machosts.AuthorizationProbe",
      "CFBundleName": "MacHosts Authorization Probe",
      "CFBundleExecutable": "MacHostsAuthorizationProbe",
      "CFBundlePackageType": "APPL",
      "CFBundleVersion": "1",
      "CFBundleShortVersionString": "0.0.1",
      "LSMinimumSystemVersion": "27.0",
      "NSHighResolutionCapable": true,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    _ = try run(
      "/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", app.path], at: root)
    _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], at: root)
    let archive = output.appendingPathComponent("MacHostsAuthorizationProbe.zip")
    _ = try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path], at: root)
    print("Created accountless, ad-hoc-signed experiment: \(archive.path)")
  }

  private static func run(_ executable: String, _ arguments: [String], at directory: URL) throws
    -> String
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let output = Pipe()
    process.standardOutput = output
    // Inherit stderr: no full build logs buffered into a pipe before waitUntilExit.
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure.commandFailed(executable, process.terminationStatus)
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
