import Darwin
import Foundation
import HostsSystem

@main
struct MacHostsApply {
  static func main() {
    guard geteuid() != 0 else { exit(64) }
    do {
      try SystemWriter.apply()
    } catch {
      FileHandle.standardError.write(Data("MacHosts: system integration unavailable.\n".utf8))
      exit(69)
    }
  }
}
