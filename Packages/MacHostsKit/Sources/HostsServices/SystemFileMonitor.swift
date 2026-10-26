import Darwin
import Dispatch
import Foundation
import HostsCore
import Synchronization

public enum SystemFileReadFailure: Error, Equatable, Sendable {
  case unavailable, unsafeFile, tooLarge, changedDuringRead, watchUnavailable
}

/// A fresh read is an observation, never a transaction receipt or recovery decision.
public enum SystemFileObservation: Equatable, Sendable {
  case readable(ContentDigest)
  case unreadable(SystemFileReadFailure)

  public func status(appliedDigest: ContentDigest?, hasPendingApply: Bool) -> SystemObservation {
    if hasPendingApply { return .recoveryRequired }
    guard case .readable(let digest) = self else { return .unconfirmed }
    guard let appliedDigest else { return .unconfirmed }
    return digest == appliedDigest ? .confirmed : .externalChange
  }
}

/// Bytes and diagnostics from the same bounded, identity-checked read as the digest.
/// Unsupported encodings remain unavailable as text; no lossy conversion is performed.
public struct SystemFileContents: Equatable, Sendable {
  public let digest: ContentDigest
  public let source: String?
  public let diagnostics: [HostsDiagnostic]

  init(data: Data) {
    digest = ContentDigest(data)
    let document = HostsDocument.parse(data, context: .system)
    diagnostics = document.diagnostics
    source =
      diagnostics.contains { $0.code == .unsupportedEncoding }
      ? nil
      : String(data: data, encoding: .utf8)
  }
}

/// The cancellation handler owns the descriptor until Dispatch has stopped delivering events.
private final class DirectoryWatch: Sendable {
  private let source: Mutex<(any DispatchSourceFileSystemObject)?>

  init(descriptor: Int32, event: @escaping @Sendable (Bool) -> Void) {
    let watch = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
      queue: DispatchQueue(label: "de.machosts.file-observation"))
    source = Mutex(watch)
    watch.setEventHandler { [weak self] in
      let invalid =
        self?.source.withLock { value in
          !(value?.data.intersection([.rename, .delete, .revoke]).isEmpty ?? true)
        } ?? true
      event(invalid)
    }
    watch.setCancelHandler { close(descriptor) }
    watch.resume()
  }

  func cancel() {
    source.withLock { value in
      value?.cancel()
      value = nil
    }
  }

  deinit { cancel() }
}

/// Read-only, event-driven monitoring. Watching the directory survives replacement of the file
/// inode. No polling, authorization, workspace mutation, or write capability is involved.
public actor SystemFileMonitor {
  private let directory: String
  private let filename: String
  private let debounce: Duration
  private var watch: DirectoryWatch?
  private var fileWatch: DirectoryWatch?
  private var continuation: AsyncStream<SystemFileObservation>.Continuation?
  private var pendingRead: Task<Void, Never>?
  private var contents: SystemFileContents?
  private var last: SystemFileObservation?
  private var watchInvalid = false
  private var generation: UInt64 = 0

  public init() {
    directory = "/private/etc"
    filename = "hosts"
    debounce = .milliseconds(100)
  }

  /// Internal fixture seam; it exposes no configurable production write destination.
  init(directory: URL, filename: String = "hosts", debounce: Duration = .milliseconds(30)) {
    self.directory = directory.path
    self.filename = filename
    self.debounce = debounce
  }

  /// A new subscription replaces the old one. The newest observation is buffered for slow UI consumers.
  public func start() throws -> AsyncStream<SystemFileObservation> {
    stop()
    let descriptor = open(directory, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw SystemFileReadFailure.watchUnavailable }
    let token = generation
    let stream = AsyncStream<SystemFileObservation>.makeStream(bufferingPolicy: .bufferingNewest(1))
    continuation = stream.continuation
    stream.continuation.onTermination = { [weak self] _ in
      Task { await self?.stop(ifGeneration: token) }
    }
    watch = DirectoryWatch(descriptor: descriptor) { [weak self] invalid in
      Task { await self?.directoryEvent(generation: token, invalid: invalid) }
    }
    refresh()
    return stream.stream
  }

  public func stop() {
    generation &+= 1
    pendingRead?.cancel()
    pendingRead = nil
    watch?.cancel()
    watch = nil
    fileWatch?.cancel()
    fileWatch = nil
    continuation?.finish()
    continuation = nil
    contents = nil
    last = nil
    watchInvalid = false
  }

  /// Also usable after wake or a confirmed apply. Digest equality suppresses self-write echoes;
  /// an observation must still be compared with the latest persisted receipt by the caller.
  public func refresh() {
    guard continuation != nil else { return }
    let observation: SystemFileObservation
    do {
      guard !watchInvalid else { throw SystemFileReadFailure.watchUnavailable }
      attachFileWatch()
      let data = try read()
      let digest = ContentDigest(data)
      if contents?.digest != digest { contents = SystemFileContents(data: data) }
      observation = .readable(digest)
    } catch let error as SystemFileReadFailure {
      observation = .unreadable(error)
    } catch {
      observation = .unreadable(.unavailable)
    }
    if case .unreadable = observation { contents = nil }
    if observation != last {
      last = observation
      continuation?.yield(observation)
    }
  }

  /// A queued observation may already have been superseded. Never pair its digest
  /// with different bytes, or expose a previous successful read after a failure.
  public func contents(matching observation: SystemFileObservation) -> SystemFileContents? {
    guard case .readable(let digest) = observation, contents?.digest == digest else { return nil }
    return contents
  }

  private func stop(ifGeneration token: UInt64) {
    if token == generation { stop() }
  }

  private func directoryEvent(generation token: UInt64, invalid: Bool) {
    guard token == generation else { return }
    if invalid {
      watchInvalid = true
      watch?.cancel()
      watch = nil
      fileWatch?.cancel()
      fileWatch = nil
      pendingRead?.cancel()
      refresh()
      return
    }
    scheduleRead(generation: token)
  }

  private func scheduleRead(generation token: UInt64) {
    guard token == generation, continuation != nil else { return }
    pendingRead?.cancel()
    let delay = debounce
    pendingRead = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard !Task.isCancelled else { return }
      await self?.refresh(ifGeneration: token)
    }
  }

  private func refresh(ifGeneration token: UInt64) {
    if token == generation { refresh() }
  }

  // Directory events cover name changes; in-place writes require a watch on the current inode.
  // Reattach before reading so later writes cannot fall between the read and registration.
  private func attachFileWatch() {
    fileWatch?.cancel()
    fileWatch = nil
    let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { return }
    defer { close(parent) }
    let file = openat(parent, filename, O_EVTONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard file >= 0 else { return }
    var metadata = stat()
    guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1
    else {
      close(file)
      return
    }
    let token = generation
    fileWatch = DirectoryWatch(descriptor: file) { [weak self] _ in
      Task { await self?.scheduleRead(generation: token) }
    }
  }

  private func read() throws -> Data {
    let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw SystemFileReadFailure.watchUnavailable }
    defer { close(parent) }
    let file = openat(parent, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard file >= 0 else { throw SystemFileReadFailure.unavailable }
    defer { close(file) }
    var before = stat()
    guard fstat(file, &before) == 0 else { throw SystemFileReadFailure.unavailable }
    guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
      throw SystemFileReadFailure.unsafeFile
    }
    let limit = 4 * 1024 * 1024
    guard before.st_size <= limit else { throw SystemFileReadFailure.tooLarge }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = Darwin.read(file, &buffer, min(buffer.count, limit + 1 - result.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw SystemFileReadFailure.unavailable
      }
      if count == 0 { break }
      result.append(contentsOf: buffer.prefix(count))
      guard result.count <= limit else { throw SystemFileReadFailure.tooLarge }
    }
    var after = stat()
    var named = stat()
    guard fstat(file, &after) == 0,
      fstatat(parent, filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
      before.st_dev == after.st_dev, before.st_ino == after.st_ino,
      after.st_dev == named.st_dev, after.st_ino == named.st_ino,
      before.st_size == after.st_size, result.count == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw SystemFileReadFailure.changedDuringRead }
    return result
  }
}
