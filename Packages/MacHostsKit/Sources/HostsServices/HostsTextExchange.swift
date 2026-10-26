import Darwin
import Foundation
import HostsCore

public enum HostsTextExchangeFailure: Error, Equatable, Sendable {
  case unreadable, sizeLimit, unsupportedEncoding, incompleteDocument, invalidEntries
  case destinationExists, writeFailed
}

/// A frozen UTF-8 source snapshot. Syntax errors remain reviewable/editable drafts;
/// encoding and parser limits never result in partial imports.
public struct HostsTextImport: Sendable {
  public let source: String
  public let document: HostsDocument

  public init(data: Data) throws {
    guard data.count <= HostsLimits.profileBytes else { throw HostsTextExchangeFailure.sizeLimit }
    let document = HostsDocument.parse(data, context: .profile)
    guard !document.diagnostics.contains(where: { $0.code == .unsupportedEncoding }),
      let source = String(data: data, encoding: .utf8)
    else { throw HostsTextExchangeFailure.unsupportedEncoding }
    guard !document.diagnostics.contains(where: { $0.code == .lineLimit }) else {
      throw HostsTextExchangeFailure.incompleteDocument
    }
    self.source = source
    self.document = document
  }
}

public enum HostsTextExportMode: Sendable { case source, enabledEntries }

/// Unprivileged exchange only. Files are bounded while reading; export exclusively
/// creates a new file and therefore cannot overwrite any existing file or link.
public actor HostsTextExchange {
  public init() {}

  public func read(_ url: URL) throws -> HostsTextImport {
    guard url.isFileURL else { throw HostsTextExchangeFailure.unreadable }
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw HostsTextExchangeFailure.unreadable }
    defer { close(fd) }
    var metadata = stat()
    guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      throw HostsTextExchangeFailure.unreadable
    }
    guard metadata.st_size <= HostsLimits.profileBytes else {
      throw HostsTextExchangeFailure.sizeLimit
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      try Task.checkCancellation()
      let count = Darwin.read(
        fd, &buffer, min(buffer.count, HostsLimits.profileBytes + 1 - data.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw HostsTextExchangeFailure.unreadable
      }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= HostsLimits.profileBytes else { throw HostsTextExchangeFailure.sizeLimit }
    }
    return try HostsTextImport(data: data)
  }

  public func data(source: String, mode: HostsTextExportMode) throws -> Data {
    let original = Data(source.utf8)
    guard original.count <= HostsLimits.profileBytes else {
      throw HostsTextExchangeFailure.sizeLimit
    }
    switch mode {
    case .source:
      return original
    case .enabledEntries:
      let snapshot = try HostsTextImport(data: original)
      guard snapshot.document.diagnostics.isEmpty else {
        throw HostsTextExchangeFailure.invalidEntries
      }
      // Keep original spelling, aliases, comments and line endings of enabled records.
      var result = Data()
      for line in snapshot.document.lines {
        if case .entry(let entry) = line.kind, entry.isEnabled {
          result.append(snapshot.document.data.subdata(in: line.bytes))
        }
      }
      return result
    }
  }

  /// The destination must be new. O_EXCL also refuses dangling symlinks/hardlinks,
  /// including aliases to the workstation hosts file; no overwrite fallback exists.
  public func writeNew(_ data: Data, to url: URL) throws {
    guard url.isFileURL, data.count <= HostsLimits.profileBytes else {
      throw HostsTextExchangeFailure.writeFailed
    }
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw errno == EEXIST
        ? HostsTextExchangeFailure.destinationExists : HostsTextExchangeFailure.writeFailed
    }
    // A failed write may leave a partial new export. Preserve it and report failure;
    // never unlink a pathname that another process could have replaced.
    defer { close(fd) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        guard let base = bytes.baseAddress else { throw HostsTextExchangeFailure.writeFailed }
        let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw HostsTextExchangeFailure.writeFailed }
        offset += count
      }
    }
    guard fsync(fd) == 0 else { throw HostsTextExchangeFailure.writeFailed }
  }
}
