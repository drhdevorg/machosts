import Foundation

/// Active entries in the system file that MacHosts does not manage. It counts mappings
/// outside the managed block and separates the macOS default loopback/broadcast lines,
/// so first launch can show that something else already maintains the file.
public struct ForeignEntrySummary: Equatable, Sendable {
  /// Active entries outside the managed block other than the macOS defaults.
  public let foreignEntries: Int
  /// Hostname mappings in those entries.
  public let foreignHostnames: Int
  /// `127.0.0.1 localhost`, `255.255.255.255 broadcasthost`, `::1 localhost`.
  public let defaultEntries: Int
  public let hasManagedBlock: Bool

  public init(_ document: HostsDocument) {
    var foreign = 0
    var hostnames = 0
    var defaults = 0
    for line in document.lines {
      guard case .entry(let entry) = line.kind, entry.isEnabled else { continue }
      if let block = document.managedBlock, block.contains(line.bytes.lowerBound) { continue }
      if Self.isDefault(entry) {
        defaults += 1
      } else {
        foreign += 1
        hostnames += entry.hostnames.count
      }
    }
    foreignEntries = foreign
    foreignHostnames = hostnames
    defaultEntries = defaults
    hasManagedBlock = document.managedBlock != nil
  }

  private static func isDefault(_ entry: HostsEntry) -> Bool {
    switch entry.address.canonical {
    case "127.0.0.1", "::1": entry.hostnames == ["localhost"]
    case "255.255.255.255": entry.hostnames == ["broadcasthost"]
    default: false
    }
  }
}

/// Source of the example profile that first launch offers. It uses documentation
/// addresses (RFC 5737, RFC 3849) and `.example` names (RFC 2606) so it can never redirect
/// a real host, and it is only ever created inactive.
public enum ExampleProfile {
  public static func source(heading: String, disabledNote: String) -> String {
    """
    # \(heading)
    203.0.113.10 app.example www.app.example
    2001:db8::10 ipv6.app.example
    # \(disabledNote)
    \(HostsSyntax.disabled)198.51.100.20 api.example

    """
  }
}
