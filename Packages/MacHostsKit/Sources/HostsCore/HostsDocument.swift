import Darwin
import Foundation

public enum HostsLimits {
  public static let profileBytes = 1_048_576
  public static let systemBytes = 4_194_304
  public static let systemLines = 50_000
  public static let workspaceBytes = 33_554_432
  public static let profiles = 500
  public static let folderDepth = 16
}

public enum HostsSyntax {
  public static let begin = "# >>> MacHosts managed block v1 >>>"
  public static let end = "# <<< MacHosts managed block v1 <<<"
  public static let disabled = "# machosts-disabled: "
}

public struct IPAddress: Hashable, Codable, Sendable {
  public enum Family: String, Codable, Sendable { case ipv4, ipv6 }
  public let canonical: String
  public let family: Family

  public init?(_ literal: String) {
    guard !literal.isEmpty,
      literal.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 46
          || $0 == 58
      })
    else { return nil }
    if literal.contains(":"), literal.contains(".") {
      guard let suffix = literal.split(separator: ":").last,
        IPAddress(String(suffix))?.family == .ipv4
      else { return nil }
    }
    var v4 = in_addr()
    var v6 = in6_addr()
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    if inet_pton(AF_INET, literal, &v4) == 1 {
      guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
      // Darwin accepts ambiguous leading-zero forms; hosts input uses strict decimal octets.
      guard
        literal.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
          $0.count == 1 || $0.first != "0"
        })
      else { return nil }
      family = .ipv4
    } else if inet_pton(AF_INET6, literal, &v6) == 1 {
      guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
      family = .ipv6
    } else {
      return nil
    }
    canonical = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let address = IPAddress(value) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IP literal")
    }
    self = address
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(canonical)
  }
}

public struct HostsEntry: Equatable, Sendable {
  public let address: IPAddress
  /// ASCII lowercase; a single final DNS root dot is normalized away.
  public let hostnames: [String]
  public let comment: String?
  public let isEnabled: Bool
}

public struct HostsDiagnostic: Equatable, Sendable {
  public enum Code: String, Sendable {
    case unsupportedEncoding, sizeLimit, lineLimit, controlCharacter, invalidAddress
    case missingHostname, invalidHostname, reservedMarker, malformedMarkers
  }
  public let code: Code
  public let line: Int?
}

public struct HostsLine: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case blank, comment, marker, invalid
    case entry(HostsEntry)
  }
  public let number: Int
  /// UTF-8 byte offsets, including the original line terminator.
  public let bytes: Range<Int>
  public let content: String
  public let ending: String
  public let kind: Kind
}

public struct HostsDocument: Equatable, Sendable {
  public enum Context: Sendable { case profile, system }
  public let data: Data
  public let lines: [HostsLine]
  public let diagnostics: [HostsDiagnostic]
  public let managedBlock: Range<Int>?

  public static func parse(_ data: Data, context: Context) -> HostsDocument {
    // Data slices can retain nonzero indices; public byte ranges are always zero-based offsets.
    let data = Data(data)
    let limit = context == .profile ? HostsLimits.profileBytes : HostsLimits.systemBytes
    guard data.count <= limit else {
      return HostsDocument(
        data: data, lines: [], diagnostics: [.init(code: .sizeLimit, line: nil)], managedBlock: nil)
    }
    guard String(data: data, encoding: .utf8) != nil, !data.starts(with: [0xef, 0xbb, 0xbf]) else {
      return HostsDocument(
        data: data, lines: [], diagnostics: [.init(code: .unsupportedEncoding, line: nil)],
        managedBlock: nil)
    }
    let bytes = Array(data)
    var lines: [HostsLine] = []
    var diagnostics: [HostsDiagnostic] = []
    var start = 0
    var begins: [Int] = []
    var ends: [Int] = []
    while start < bytes.count {
      guard lines.count < HostsLimits.systemLines else {
        diagnostics.append(.init(code: .lineLimit, line: nil))
        break
      }
      var end = start
      while end < bytes.count && bytes[end] != 10 && bytes[end] != 13 { end += 1 }
      var next = end
      if next < bytes.count {
        next += 1
        if bytes[end] == 13 && next < bytes.count && bytes[next] == 10 { next += 1 }
      }
      let content = String(decoding: bytes[start..<end], as: UTF8.self)
      let ending = String(decoding: bytes[end..<next], as: UTF8.self)
      let number = lines.count + 1
      let kind: HostsLine.Kind
      if context == .system && (content == HostsSyntax.begin || content == HostsSyntax.end) {
        if content == HostsSyntax.begin {
          begins.append(lines.count)
        } else {
          ends.append(lines.count)
        }
        kind = .marker
      } else {
        let result = parseLine(content, context: context)
        kind = result.0
        if let code = result.1 { diagnostics.append(.init(code: code, line: number)) }
      }
      lines.append(
        .init(number: number, bytes: start..<next, content: content, ending: ending, kind: kind))
      start = next
    }
    var block: Range<Int>?
    if !begins.isEmpty || !ends.isEmpty {
      if begins.count == 1, ends.count == 1, let first = begins.first, let last = ends.first,
        first < last
      {
        block = lines[first].bytes.lowerBound..<lines[last].bytes.upperBound
      } else {
        diagnostics.append(.init(code: .malformedMarkers, line: nil))
      }
    }
    return HostsDocument(data: data, lines: lines, diagnostics: diagnostics, managedBlock: block)
  }

  private static func parseLine(_ text: String, context: Context) -> (
    HostsLine.Kind, HostsDiagnostic.Code?
  ) {
    if text.unicodeScalars.contains(where: {
      ($0.value < 32 && $0.value != 9) || (127...159).contains($0.value)
    }) {
      return (.invalid, .controlCharacter)
    }
    // Also reject embedded markers, so comments cannot inject a future delimiter.
    if text.contains("# >>> MacHosts managed block")
      || text.contains("# <<< MacHosts managed block")
    {
      return (.invalid, .reservedMarker)
    }
    var content = text
    var enabled = true
    if context == .profile && content.hasPrefix(HostsSyntax.disabled) {
      enabled = false
      content.removeFirst(HostsSyntax.disabled.count)
    }
    let trimmed = content.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return enabled ? (.blank, nil) : (.invalid, .missingHostname) }
    if trimmed.hasPrefix("#") { return enabled ? (.comment, nil) : (.invalid, .invalidAddress) }
    let parts = content.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let tokens = parts[0].split { $0 == " " || $0 == "\t" }
    guard let first = tokens.first, let address = IPAddress(String(first)) else {
      return (.invalid, .invalidAddress)
    }
    guard tokens.count > 1 else { return (.invalid, .missingHostname) }
    var hostnames: [String] = []
    for token in tokens.dropFirst() {
      guard let hostname = normalizeHostname(String(token)) else {
        return (.invalid, .invalidHostname)
      }
      hostnames.append(hostname)
    }
    return (
      .entry(
        .init(
          address: address, hostnames: hostnames, comment: parts.count > 1 ? String(parts[1]) : nil,
          isEnabled: enabled)), nil
    )
  }

  public static func normalizeHostname(_ value: String) -> String? {
    guard value.utf8.allSatisfy({ $0 < 128 }) else { return nil }
    let name = value.hasSuffix(".") ? String(value.dropLast()) : value
    guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    for label in labels {
      guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-",
        label.utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        })
      else { return nil }
    }
    return name.lowercased()
  }
}
