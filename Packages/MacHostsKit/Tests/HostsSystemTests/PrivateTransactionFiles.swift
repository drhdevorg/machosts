import Darwin
import Foundation
import HostsCore
import Testing

@testable import HostsSystem

enum FixtureFailure: Error, Equatable {
  case unsafe
  case io(Int32)
  case injected, locked
}
enum TransactionFault: String, CaseIterable, Sendable {
  case backup, prepared, beforeRename, afterRename, readback, receipt
}

/// Always creates its own private temporary directory; cannot be pointed at a system file.
/// This deliberately narrow adapter supports only user-owned 0600 fixture files without ACLs/flags; OS provenance is verified byte-for-byte.
final class PrivateTransactionFiles: TransactionFiles {
  let directory: URL
  let directoryFD: Int32
  let lockFD: Int32
  let cleanupOnDeinit: Bool
  var retirementSyncFailure = false
  var retirementRenameInterruption: ((Bool) throws -> Void)?
  var retirementInterruption: ((Bool) throws -> Void)?
  var fault: TransactionFault?
  var interruption: ((TransactionFault) -> Void)?
  var beforeRename: (() throws -> Void)?

  init(_ original: Data, cleanupOnDeinit: Bool = true) throws {
    self.cleanupOnDeinit = cleanupOnDeinit
    guard geteuid() != 0 else { throw FixtureFailure.unsafe }
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "machosts-transaction-" + UUID().uuidString, isDirectory: true)
    guard mkdir(directory.path, 0o700) == 0 else { throw FixtureFailure.io(errno) }
    let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw FixtureFailure.io(errno) }
    directoryFD = root
    let lock = openat(root, ".lock", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0 else {
      close(root)
      throw FixtureFailure.io(errno)
    }
    lockFD = lock
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      close(lock)
      close(root)
      throw FixtureFailure.locked
    }
    do { try publish(original, name: "target") } catch {
      close(lock)
      close(root)
      throw error
    }
  }

  /// Reopens only a private fixture created by this test harness, never a product target.
  init(reopening directory: URL) throws {
    guard geteuid() != 0,
      directory.deletingLastPathComponent().standardizedFileURL
        == FileManager.default.temporaryDirectory.standardizedFileURL,
      directory.lastPathComponent.hasPrefix("machosts-transaction-")
    else { throw FixtureFailure.unsafe }
    self.directory = directory
    cleanupOnDeinit = false
    let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw FixtureFailure.io(errno) }
    var info = stat()
    guard fstat(root, &info) == 0, info.st_uid == geteuid(),
      info.st_mode & 0o7777 == 0o700
    else {
      close(root)
      throw FixtureFailure.unsafe
    }
    directoryFD = root
    let lock = openat(root, ".lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard lock >= 0 else {
      close(root)
      throw FixtureFailure.io(errno)
    }
    guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600
    else {
      close(lock)
      close(root)
      throw FixtureFailure.unsafe
    }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      close(lock)
      close(root)
      throw FixtureFailure.locked
    }
    lockFD = lock
  }

  deinit {
    close(lockFD)
    close(directoryFD)
    guard cleanupOnDeinit else { return }
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Private transaction fixture cleanup failed: \(error)")
    }
  }

  func hit(_ point: TransactionFault) throws {
    interruption?(point)
    if fault == point { throw FixtureFailure.injected }
  }

  func synchronizeTarget() throws {
    let fd = openat(directoryFD, "target", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw FixtureFailure.io(errno) }
    defer { close(fd) }
    guard fsync(fd) == 0, fsync(directoryFD) == 0 else { throw FixtureFailure.io(errno) }
  }

  func readTarget() throws -> TransactionSnapshot {
    try read("target", limit: HostsLimits.systemBytes)
  }

  private func read(_ name: String, limit: Int = 8_388_608) throws -> TransactionSnapshot {
    let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw FixtureFailure.io(errno) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw FixtureFailure.io(errno) }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
      info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600, info.st_flags == 0,
      info.st_size >= 0, info.st_size <= limit
    else { throw FixtureFailure.unsafe }
    let provenance = try readProvenance(fd)
    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
      defer { acl_free(UnsafeMutableRawPointer(acl)) }
      guard acl_valid(acl) == 0 else { throw FixtureFailure.unsafe }
      var entry: acl_entry_t?
      // Darwin returns -1/EINVAL for end of a valid ACL.
      errno = 0
      guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
        errno == EINVAL, entry == nil
      else { throw FixtureFailure.unsafe }
    } else if errno != ENOENT {
      throw FixtureFailure.io(errno)
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw FixtureFailure.io(errno)
      }
      if count == 0 { break }
      guard data.count <= limit - count else { throw FixtureFailure.unsafe }
      data.append(contentsOf: buffer.prefix(count))
    }
    var after = stat()
    guard fstat(fd, &after) == 0,
      info.st_size == after.st_size, data.count == info.st_size,
      info.st_uid == after.st_uid, info.st_gid == after.st_gid,
      info.st_mode == after.st_mode, info.st_flags == after.st_flags,
      info.st_nlink == after.st_nlink,
      info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw FixtureFailure.unsafe }
    return TransactionSnapshot(
      data: data, device: info.st_dev, inode: info.st_ino,
      modificationSeconds: Int64(info.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      changeSeconds: Int64(info.st_ctimespec.tv_sec),
      changeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
      metadata: .init(
        owner: info.st_uid, group: info.st_gid, mode: info.st_mode & 0o7777,
        provenance: provenance))
  }

  private func readProvenance(_ fd: Int32) throws -> Data? {
    let count = flistxattr(fd, nil, 0, 0)
    guard count >= 0, count <= 256 else { throw FixtureFailure.unsafe }
    if count == 0 { return nil }
    var names = [CChar](repeating: 0, count: count)
    guard flistxattr(fd, &names, names.count, 0) == count,
      names.map({ UInt8(bitPattern: $0) }) == Array("com.apple.provenance\0".utf8)
    else { throw FixtureFailure.unsafe }
    let size = fgetxattr(fd, "com.apple.provenance", nil, 0, 0, 0)
    guard size >= 0, size <= 256 else { throw FixtureFailure.unsafe }
    var bytes = [UInt8](repeating: 0, count: size)
    guard fgetxattr(fd, "com.apple.provenance", &bytes, bytes.count, 0, 0) == size else {
      throw FixtureFailure.unsafe
    }
    return Data(bytes)
  }

  func journals() throws -> [FileTransactionJournal] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return try names.filter { $0.hasSuffix(".journal") }.map { name in
      let record = try JSONDecoder().decode(FileTransactionJournal.self, from: read(name).data)
      guard name == record.transactionID.uuidString + ".journal" else {
        throw FileTransactionFailure.invalidJournal
      }
      return record
    }
  }

  func saveJournal(_ journal: FileTransactionJournal) throws {
    try journal.validate()
    try hit(journal.phase == .prepared ? .prepared : .receipt)
    try publish(JSONEncoder().encode(journal), name: journal.transactionID.uuidString + ".journal")
  }

  func retirements() throws -> [ApplyRetirement] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return try names.filter { $0.hasSuffix(".retired") }.map { name in
      let record = try JSONDecoder().decode(ApplyRetirement.self, from: read(name).data)
      guard name == record.transactionID.uuidString + ".retired" else {
        throw FileTransactionFailure.invalidJournal
      }
      return record
    }
  }

  func synchronizeRetirement(_ transactionID: UUID) throws {
    if retirementSyncFailure { throw FixtureFailure.injected }
    let name = transactionID.uuidString + ".retired"
    _ = try read(name)
    let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw FixtureFailure.io(errno) }
    defer { close(fd) }
    guard fsync(fd) == 0, fsync(directoryFD) == 0 else { throw FixtureFailure.io(errno) }
  }

  func saveRetirement(_ retirement: ApplyRetirement) throws {
    try retirement.validate()
    try retirementInterruption?(false)
    try publish(
      JSONEncoder().encode(retirement), name: retirement.transactionID.uuidString + ".retired",
      exclusive: true, renameInterruption: retirementRenameInterruption)
    try retirementInterruption?(true)
  }

  func saveBackup(_ original: TransactionSnapshot, id: UUID) throws {
    try hit(.backup)
    try publish(JSONEncoder().encode(original), name: id.uuidString + ".backup", exclusive: true)
  }

  func readBackup(_ id: UUID) throws -> TransactionSnapshot {
    try JSONDecoder().decode(TransactionSnapshot.self, from: read(id.uuidString + ".backup").data)
  }

  func replaceTarget(_ data: Data, expecting original: TransactionSnapshot) throws {
    try publish(data, name: "target", expected: original)
  }

  /// Models a new worker under the retained exclusive lock, after an interrupted synchronous call.
  func restartSession() -> FileTransaction {
    fault = nil
    beforeRename = nil
    return FileTransaction(files: self)
  }

  func mutateTarget(_ data: Data) throws { try publish(data, name: "target") }

  func corruptBackup(_ id: UUID) throws {
    try publish(Data("broken".utf8), name: id.uuidString + ".backup")
  }

  func verifySecondLockIsRejected() throws {
    let fd = openat(directoryFD, ".lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw FixtureFailure.io(errno) }
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == -1)
    #expect(errno == EWOULDBLOCK)
  }

  private func publish(
    _ data: Data, name: String, exclusive: Bool = false, expected: TransactionSnapshot? = nil,
    renameInterruption: ((Bool) throws -> Void)? = nil
  ) throws {
    // All names are generated internally from fixed literals or typed UUIDs.
    var existing = stat()
    let exists = fstatat(directoryFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0
    if exists {
      guard !exclusive else { throw FixtureFailure.unsafe }
      _ = try read(name)
    } else if errno != ENOENT {
      throw FixtureFailure.io(errno)
    }
    let temporary = ".new-" + UUID().uuidString
    let fd = openat(
      directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw FixtureFailure.io(errno) }
    defer {
      close(fd)
      unlinkat(directoryFD, temporary, 0)
    }
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        guard let address = raw.baseAddress else { throw FixtureFailure.unsafe }
        let written = Darwin.write(fd, address.advanced(by: offset), raw.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw FixtureFailure.io(errno)
        }
        guard written > 0 else { throw FixtureFailure.io(EIO) }
        offset += written
      }
    }
    guard fsync(fd) == 0 else { throw FixtureFailure.io(errno) }
    if let expected {
      try hit(.beforeRename)
      try beforeRename?()
      guard try readTarget() == expected else { throw FileTransactionFailure.staleFile }
      // This OS-managed attribute is synthesized on new files. Never replace when it differs.
      guard try readProvenance(fd) == expected.metadata.provenance else {
        throw FixtureFailure.unsafe
      }
    }
    try renameInterruption?(false)
    guard renameat(directoryFD, temporary, directoryFD, name) == 0 else {
      throw FixtureFailure.io(errno)
    }
    try renameInterruption?(true)
    if expected != nil { try hit(.afterRename) }
    guard fsync(directoryFD) == 0 else { throw FixtureFailure.io(errno) }
    if expected != nil {
      try hit(.readback)
      guard try readTarget().data == data else { throw FileTransactionFailure.readbackMismatch }
    }
  }
}
