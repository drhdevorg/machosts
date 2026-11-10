import Darwin
import Foundation
import Testing

@testable import HostsCore

/// Deterministic generator so failures are reproducible.
private struct SplitMix: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var value = state
    value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
    value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
    return value ^ (value >> 31)
  }
}

/// Fragments chosen to hit grapheme-cluster edges: combining marks after `#`, space or tab,
/// non-ASCII spaces, ZWJ, IPv4/IPv6 forms, hostnames with case, dots and hyphens.
private let fragments = [
  "1", "0", "9", "a", "F", ".", ":", " ", "\t", "#", "-", "x", "é", "\u{301}", "\u{A0}",
  "\u{3000}", "\u{200D}", "ß", "K", "127.0.0.1", "::1", "2001:db8::1", "::ffff:192.0.2.1",
  "01.2.3.4", "host.test", "Host.Test.", "-bad", "bad-", "a..b", "# ", "😀", "_",
]

private func randomLine(_ generator: inout SplitMix) -> String {
  let count = Int(generator.next() % 9)
  return (0..<count).map { _ in fragments[Int(generator.next() % UInt64(fragments.count))] }
    .joined()
}

private let corpus = [
  "", " ", "\t", "#", "# comment", "  # indented", "127.0.0.1 localhost",
  "127.0.0.1\tlocalhost\tLOCAL.Test. # tail ü", "::1 localhost #", "203.0.113.7",
  "203.0.113.7 # only comment", "203.0.113.7 ex\u{301}ample.test", "203.0.113.7 a.test #\u{301}x",
  "203.0.113.7 \u{301}a.test", "203.0.113.7\u{A0}a.test", "#\u{301} not a comment?",
  "203.0.113.7 a.test#x", "1.2.3.4 \(String(repeating: "a", count: 63)).test",
  "1.2.3.4 \(String(repeating: "a", count: 64)).test", "1.2.3.4 ..", "1.2.3.4 .",
  "fe80::1%en0 link.test", "1.2.3.4 a.test b_c.test", "0.0.0.0 ads.test # 😀 blocked",
]

@Test func asciiFieldParserMatchesTheCharacterParserWheneverItApplies() {
  var generator = SplitMix(state: 0x4d61_6348_6f73_7473)
  var lines = corpus
  for _ in 0..<20_000 { lines.append(randomLine(&generator)) }
  var fastCount = 0
  for line in lines {
    for enabled in [true, false] {
      guard let fast = HostsDocument.parseASCIIFields(line, enabled: enabled) else { continue }
      fastCount += 1
      let reference = HostsDocument.parseCharacterFields(line, enabled: enabled)
      #expect(fast.0 == reference.0 && fast.1 == reference.1, "\(line.unicodeScalars.map(\.value))")
    }
  }
  // Both paths must be exercised substantially for the comparison to mean anything.
  #expect(fastCount > 10_000 && fastCount < lines.count * 2)
}

/// The previous Character-based implementation, kept as the oracle for the byte version.
private func referenceHostname(_ value: String) -> String? {
  guard value.utf8.allSatisfy({ $0 < 128 }) else { return nil }
  let name = value.hasSuffix(".") ? String(value.dropLast()) : value
  guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
  for label in name.split(separator: ".", omittingEmptySubsequences: false) {
    guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-",
      label.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
      })
    else { return nil }
  }
  return name.lowercased()
}

@Test func byteHostnameNormalizationMatchesTheReference() {
  var generator = SplitMix(state: 7)
  let pieces = [
    "a", "Z", "0", "-", ".", "é", "_", "xn--d", "\u{301}", "",
    "\(String(repeating: "b", count: 62))",
  ]
  var names = [
    ".", "..", "a.", "a..", "-", "a-", "-a", "A.B.C.", String(repeating: "a", count: 63),
    String(repeating: "a", count: 64), String(repeating: "a.", count: 126) + "a",
    String(repeating: "a.", count: 127), String(repeating: "a.", count: 126) + "ab.",
  ]
  for _ in 0..<20_000 {
    let count = Int(generator.next() % 8)
    names.append(
      (0..<count).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }.joined())
  }
  var valid = 0
  for name in names {
    let expected = referenceHostname(name)
    #expect(HostsDocument.normalizeHostname(name) == expected, "\(name)")
    if expected != nil { valid += 1 }
  }
  #expect(valid > 1_000)
}

/// The previous IP literal implementation, kept as the oracle for the allocation-free version.
private func referenceAddress(_ literal: String) -> IPAddress? {
  guard !literal.isEmpty,
    literal.utf8.allSatisfy({
      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 46
        || $0 == 58
    })
  else { return nil }
  if literal.contains(":"), literal.contains(".") {
    guard let suffix = literal.split(separator: ":").last,
      referenceAddress(String(suffix))?.family == .ipv4
    else { return nil }
  }
  var v4 = in_addr()
  var v6 = in6_addr()
  var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
  if inet_pton(AF_INET, literal, &v4) == 1 {
    guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
    guard
      literal.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
        $0.count == 1 || $0.first != "0"
      })
    else { return nil }
  } else if inet_pton(AF_INET6, literal, &v6) == 1 {
    guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
  } else {
    return nil
  }
  let canonical = String(
    decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  return IPAddress(canonical)
}

@Test func addressParsingMatchesTheReference() {
  var generator = SplitMix(state: 42)
  let pieces = ["0", "1", "9", "25", "255", "256", "00", "01", "a", "F", ".", ":", "::", "ffff"]
  var literals = [
    "", "0.0.0.0", "1.2.3.4", "01.2.3.4", "1.2.3.04", "1.2.3", "1.2.3.4.5", "255.255.255.255",
    "256.1.1.1", "::", "::1", "2001:DB8::1", "::ffff:192.0.2.1", "::ffff:192.0.2.01",
    "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8:9", "fe80::1", "1.2.3.4:", "0x7f.0.0.1",
  ]
  for _ in 0..<20_000 {
    let count = 1 + Int(generator.next() % 8)
    literals.append(
      (0..<count).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }.joined())
  }
  var valid = 0
  for literal in literals {
    let actual = IPAddress(literal)
    let expected = referenceAddress(literal)
    #expect(
      actual?.canonical == expected?.canonical && actual?.family == expected?.family, "\(literal)")
    if expected != nil { valid += 1 }
  }
  #expect(valid > 500)
}

@Test func reservedMarkersAreRejectedEvenWhenFollowedByACombiningMark() {
  for text in [
    "# >>> MacHosts managed block\u{301} v1", "127.0.0.1 a.test # <<< MacHosts managed block",
  ] {
    let document = HostsDocument.parse(Data(text.utf8), context: .profile)
    #expect(document.diagnostics.map(\.code) == [.reservedMarker])
  }
}
