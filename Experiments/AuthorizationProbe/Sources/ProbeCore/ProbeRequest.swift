import CryptoKit
import Foundation

public enum ProbeError: Error, Equatable, Sendable {
  case rootExecutionRefused
  case invalidRequest
  case oversized
  case staleRevision
  case unsafeFile
  case malformedMarkers
  case recoveryRequired
  case injectedFailure
}

public func digest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Experimental wire contract. No paths, command names, or shell fragments.
public struct ProbeRequest: Codable, Equatable, Sendable {
  public static let maximumBytes = 16_384
  public let version: Int
  public let transactionID: UUID
  public let expectedDigest: String
  public let operation: Operation

  public enum Operation: String, Codable, Sendable {
    // Phase 0 deliberately uses a fixed, non-configurable example mapping.
    case installExample
    case removeExample
  }

  public init(expectedDigest: String, operation: Operation) {
    version = 1
    transactionID = UUID()
    self.expectedDigest = expectedDigest
    self.operation = operation
  }

  /// Entry point for wire bytes; direct Codable decoding cannot detect duplicate keys.
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw ProbeError.oversized }
    try FlatRequestJSON.validate(data)
    let result: Self
    do { result = try JSONDecoder().decode(Self.self, from: data) } catch {
      throw ProbeError.invalidRequest
    }
    try result.validate()
    return result
  }

  public func validate() throws {
    guard version == 1, expectedDigest.utf8.count == 64,
      expectedDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw ProbeError.invalidRequest }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case version, transactionID, expectedDigest, operation
  }

  /// JSONDecoder normally ignores unknown keys; this boundary must reject them.
  public init(from decoder: any Decoder) throws {
    let arbitrary = try decoder.container(keyedBy: AnyKey.self)
    let expected = Set(CodingKeys.allCases.map(\.rawValue))
    guard Set(arbitrary.allKeys.map(\.stringValue)) == expected else {
      throw ProbeError.invalidRequest
    }
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    transactionID = try values.decode(UUID.self, forKey: .transactionID)
    expectedDigest = try values.decode(String.self, forKey: .expectedDigest)
    operation = try values.decode(Operation.self, forKey: .operation)
  }
}

/// Checks the flat wire envelope before JSONDecoder can discard duplicate keys.
/// String tokens are decoded by Foundation so escaped and literal keys compare equally.
private struct FlatRequestJSON {
  private let bytes: [UInt8]
  private var offset = 0

  static func validate(_ data: Data) throws {
    var scanner = Self(bytes: Array(data))
    try scanner.validateObject()
  }

  private mutating func validateObject() throws {
    skipWhitespace()
    try consume(123)
    skipWhitespace()
    var keys = Set<String>()
    if current != 125 {
      while true {
        let key = try string()
        guard keys.insert(key).inserted else { throw ProbeError.invalidRequest }
        skipWhitespace()
        try consume(58)
        skipWhitespace()
        if current == 34 {
          _ = try string()
        } else {
          // Only version is numeric; JSONDecoder checks its syntax and type below.
          guard key == "version" else { throw ProbeError.invalidRequest }
          let start = offset
          while let byte = current, byte != 44, byte != 125 {
            guard byte == 45 || (48...57).contains(byte) else { break }
            offset += 1
          }
          guard offset > start else { throw ProbeError.invalidRequest }
        }
        skipWhitespace()
        if current == 125 { break }
        try consume(44)
        skipWhitespace()
      }
    }
    try consume(125)
    skipWhitespace()
    guard offset == bytes.count else { throw ProbeError.invalidRequest }
  }

  private var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

  private mutating func consume(_ byte: UInt8) throws {
    guard current == byte else { throw ProbeError.invalidRequest }
    offset += 1
  }

  private mutating func skipWhitespace() {
    while let byte = current, [9, 10, 13, 32].contains(byte) { offset += 1 }
  }

  private mutating func string() throws -> String {
    let start = offset
    try consume(34)
    while let byte = current {
      offset += 1
      if byte == 92 {
        // Skip the escaped byte; the JSON decoder validates the escape itself.
        guard current != nil else { throw ProbeError.invalidRequest }
        offset += 1
      } else if byte == 34 {
        do {
          return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
        } catch {
          throw ProbeError.invalidRequest
        }
      }
    }
    throw ProbeError.invalidRequest
  }
}

private struct AnyKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

/// Byte-preserving fixed example; not the future production hosts parser.
public enum ExampleBlock {
  public static let start = "# >>> MacHosts managed block v1 >>>"
  public static let end = "# <<< MacHosts managed block v1 <<<"
  public static let content = "\(start)\n203.0.113.42 staging.example\n\(end)\n"

  public static func compose(_ original: Data, operation: ProbeRequest.Operation) throws -> Data {
    guard original.count <= 1_048_576 else { throw ProbeError.oversized }
    guard let text = String(data: original, encoding: .utf8), !text.contains("\0") else {
      throw ProbeError.invalidRequest
    }
    // Work in bytes: Swift treats CRLF as one extended grapheme cluster.
    let lines = original.split(separator: 10, omittingEmptySubsequences: false)
    var offset = 0
    var starts: [Int] = []
    var ends: [Int] = []
    for (index, line) in lines.enumerated() {
      let normalized = line.last == 13 ? line.dropLast() : line[...]
      if normalized.elementsEqual(start.utf8) { starts.append(offset) }
      if normalized.elementsEqual(end.utf8) {
        ends.append(offset + line.count + (index < lines.count - 1 ? 1 : 0))
      }
      offset += line.count + (index < lines.count - 1 ? 1 : 0)
    }
    if starts.isEmpty && ends.isEmpty {
      guard operation == .installExample else { return original }
      var result = original
      if !result.isEmpty && result.last != 10 { result.append(10) }
      result.append(Data(content.utf8))
      return result
    }
    guard starts.count == 1, ends.count == 1,
      let lower = starts.first, let upper = ends.first, lower < upper
    else { throw ProbeError.malformedMarkers }
    var result = Data(original.prefix(lower))
    if operation == .installExample { result.append(Data(content.utf8)) }
    result.append(original.dropFirst(upper))
    return result
  }
}
