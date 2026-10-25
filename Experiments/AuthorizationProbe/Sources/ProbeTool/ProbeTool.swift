import Darwin
import Foundation
import ProbeCore

@main
enum ProbeTool {
  static func main() async {
    guard geteuid() != 0, CommandLine.arguments.dropFirst() == ["--demo"] else {
      FileHandle.standardError.write(
        Data("Unprivileged --demo only; no target paths accepted.\n".utf8))
      exit(64)
    }
    do {
      let session = try SandboxSession()
      do {
        let original = try await session.snapshot()
        let request = ProbeRequest(expectedDigest: digest(original), operation: .installExample)
        let receipt = try await session.apply(request)
        try await session.restoreOriginal(expectedDigest: receipt.afterDigest)
        guard try await session.snapshot() == original else { throw ProbeError.recoveryRequired }
        try await session.close()
        print("PASS: isolated fixture apply, readback and exact restore; no system file accessed.")
      } catch {
        try await session.close()
        throw error
      }
    } catch {
      FileHandle.standardError.write(Data("Probe failed: \(error)\n".utf8))
      exit(1)
    }
  }
}
