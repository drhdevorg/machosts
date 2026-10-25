import Foundation

/// Validates the two fixed persisted schemas before Codable can discard duplicate keys.
/// Nesting is limited to the journal's receipt; arrays and additional fields are rejected.
enum TransactionJSON {
  static func validate(_ data: Data, journal: Bool) throws {
    var scanner = Scanner(bytes: Array(data))
    try scanner.object(journal: journal)
    scanner.skipWhitespace()
    guard scanner.offset == scanner.bytes.count else { throw ProbeError.recoveryRequired }
  }

  private struct Scanner {
    let bytes: [UInt8]
    var offset = 0
    var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    mutating func object(journal: Bool) throws {
      let expected: Set<String> =
        journal
        ? ["kind", "receipt"]
        : ["transactionID", "beforeDigest", "afterDigest", "unchanged"]
      skipWhitespace()
      try consume(123)
      skipWhitespace()
      var keys = Set<String>()
      while current != 125 {
        let key = try string()
        guard expected.contains(key), keys.insert(key).inserted else {
          throw ProbeError.recoveryRequired
        }
        skipWhitespace()
        try consume(58)
        skipWhitespace()
        if journal && key == "receipt" {
          try object(journal: false)
        } else if key == "unchanged" {
          let literal = current == 116 ? "true" : "false"
          for byte in literal.utf8 { try consume(byte) }
        } else {
          _ = try string()
        }
        skipWhitespace()
        if current == 125 { break }
        try consume(44)
        skipWhitespace()
        guard current != 125 else { throw ProbeError.recoveryRequired }
      }
      try consume(125)
      guard keys == expected else { throw ProbeError.recoveryRequired }
    }

    mutating func consume(_ byte: UInt8) throws {
      guard current == byte else { throw ProbeError.recoveryRequired }
      offset += 1
    }

    mutating func skipWhitespace() {
      while let byte = current, [9, 10, 13, 32].contains(byte) { offset += 1 }
    }

    mutating func string() throws -> String {
      let start = offset
      try consume(34)
      while let byte = current {
        offset += 1
        if byte == 92 {
          guard current != nil else { throw ProbeError.recoveryRequired }
          offset += 1
        } else if byte == 34 {
          do {
            return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
          } catch {
            throw ProbeError.recoveryRequired
          }
        }
      }
      throw ProbeError.recoveryRequired
    }
  }
}
