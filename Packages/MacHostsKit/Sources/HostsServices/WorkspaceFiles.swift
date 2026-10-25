import Darwin
import Foundation
import HostsCore

public enum WorkspaceStoreFailure: Error, Equatable, Sendable {
  case privilegedProcess, unsafeFile, alreadyOpen
  case io(Int32)
  case fileTooLarge
  case readOnly, notLoaded, staleGeneration, staleRevision, externalChange
  case commitOutcomeUnknown, generationOverflow
}

/// Fault points exercise the actual file transaction; unavailable to product callers.
enum WorkspaceWritePoint: Sendable { case beforeWrite, beforeRename, afterRename }

/// Descriptor-relative access is confined to a private, user-owned directory.
/// The store actor owns this instance and holds its process lock for its lifetime.
final class WorkspaceFiles: Sendable {
  let directoryFD: Int32
  let lockFD: Int32
  let fault: (@Sendable (WorkspaceWritePoint) throws -> Void)?

  init(directory: URL, fault: (@Sendable (WorkspaceWritePoint) throws -> Void)? = nil) throws {
    guard geteuid() != 0 else { throw WorkspaceStoreFailure.privilegedProcess }
    guard directory.isFileURL else { throw WorkspaceStoreFailure.unsafeFile }
    if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
      throw WorkspaceStoreFailure.io(errno)
    }
    let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw WorkspaceStoreFailure.io(errno) }
    do {
      var info = stat()
      guard fstat(root, &info) == 0 else { throw WorkspaceStoreFailure.io(errno) }
      guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_mode & S_IFMT == S_IFDIR
      else {
        throw WorkspaceStoreFailure.unsafeFile
      }
      let lock = openat(
        root, ".workspace.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
      guard lock >= 0 else { throw WorkspaceStoreFailure.io(errno) }
      do {
        try Self.checkFile(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
          if errno == EWOULDBLOCK { throw WorkspaceStoreFailure.alreadyOpen }
          throw WorkspaceStoreFailure.io(errno)
        }
      } catch {
        close(lock)
        throw error
      }
      directoryFD = root
      lockFD = lock
      self.fault = fault
    } catch {
      close(root)
      throw error
    }
  }

  deinit {
    // Closing the descriptor releases flock; never unlink the lock inode.
    close(lockFD)
    close(directoryFD)
  }

  private static func checkFile(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw WorkspaceStoreFailure.io(errno) }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
      info.st_mode & 0o077 == 0
    else { throw WorkspaceStoreFailure.unsafeFile }
  }

  func read(_ name: String) throws -> Data? {
    let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT { return nil }
      throw WorkspaceStoreFailure.io(errno)
    }
    defer { close(fd) }
    try Self.checkFile(fd)
    var before = stat()
    guard fstat(fd, &before) == 0 else { throw WorkspaceStoreFailure.io(errno) }
    guard before.st_size >= 0, before.st_size <= HostsLimits.workspaceBytes else {
      throw WorkspaceStoreFailure.fileTooLarge
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw WorkspaceStoreFailure.io(errno)
      }
      if count == 0 { break }
      guard data.count <= HostsLimits.workspaceBytes - count else {
        throw WorkspaceStoreFailure.fileTooLarge
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    var after = stat()
    guard fstat(fd, &after) == 0 else { throw WorkspaceStoreFailure.io(errno) }
    guard before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec, Int64(data.count) == after.st_size
    else {
      throw WorkspaceStoreFailure.externalChange
    }
    return data
  }

  func checkCurrent(_ expected: ContentDigest?) throws {
    guard try read("workspace.json").map(ContentDigest.init) == expected else {
      throw WorkspaceStoreFailure.externalChange
    }
  }

  func writeSnapshot(_ data: Data, previous: Data?) throws {
    let expected = previous.map(ContentDigest.init)
    try checkCurrent(expected)
    if let previous {
      try publish(previous, name: "workspace.previous.json", faultInjection: false)
    }
    try publish(data, name: "workspace.json", expected: expected, faultInjection: true)
  }

  func recoverSnapshot(_ data: Data, preserving original: Data?) throws {
    let expected = original.map(ContentDigest.init)
    try checkCurrent(expected)
    if let original {
      try publish(
        original, name: "workspace.recovery-" + UUID().uuidString + ".json", faultInjection: false)
    }
    try publish(data, name: "workspace.json", expected: expected, faultInjection: true)
  }

  private func publish(
    _ data: Data, name: String, expected: ContentDigest? = nil, faultInjection: Bool
  ) throws {
    let temp = ".snapshot-" + UUID().uuidString + ".tmp"
    let fd = openat(directoryFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw WorkspaceStoreFailure.io(errno) }
    defer {
      close(fd)
      unlinkat(directoryFD, temp, 0)
    }
    var renamed = false
    do {
      if faultInjection { try fault?(.beforeWrite) }
      try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          guard let base = raw.baseAddress else { throw WorkspaceStoreFailure.unsafeFile }
          let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
          if written < 0 {
            if errno == EINTR { continue }
            throw WorkspaceStoreFailure.io(errno)
          }
          guard written > 0 else { throw WorkspaceStoreFailure.io(EIO) }
          offset += written
        }
      }
      guard fsync(fd) == 0 else { throw WorkspaceStoreFailure.io(errno) }
      if faultInjection {
        try fault?(.beforeRename)
        try checkCurrent(expected)
      }
      guard renameat(directoryFD, temp, directoryFD, name) == 0 else {
        throw WorkspaceStoreFailure.io(errno)
      }
      renamed = true
      if faultInjection { try fault?(.afterRename) }
      guard fsync(directoryFD) == 0 else { throw WorkspaceStoreFailure.io(errno) }
      guard try read(name) == data else { throw WorkspaceStoreFailure.externalChange }
    } catch {
      if renamed { throw WorkspaceStoreFailure.commitOutcomeUnknown }
      throw error
    }
  }
}
