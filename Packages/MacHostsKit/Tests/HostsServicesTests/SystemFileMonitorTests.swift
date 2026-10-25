import Foundation
import HostsCore
import Testing

@testable import HostsServices

private actor ObservationLog {
  var values: [SystemFileObservation] = []
  func append(_ value: SystemFileObservation) { values.append(value) }
  func snapshot() -> [SystemFileObservation] { values }
}

private struct MonitorFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "machosts-monitor-" + UUID().uuidString)
  var file: URL { directory.appendingPathComponent("hosts") }
  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }
  func cleanup() {
    do { try FileManager.default.removeItem(at: directory) } catch {
      Issue.record("Monitor fixture cleanup failed")
    }
  }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(3)
  while !(await condition()) {
    guard ContinuousClock.now < deadline else {
      Issue.record("File observation did not arrive within deadline")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

@Test func monitorTracksReplacementDeletionRecreationAndSuppressesIdenticalBytes() async throws {
  let fixture = try MonitorFixture()
  defer { fixture.cleanup() }
  let original = Data("# foreign\n127.0.0.1 localhost\n".utf8)
  try original.write(to: fixture.file)
  let monitor = SystemFileMonitor(directory: fixture.directory)
  let stream = try await monitor.start()
  let log = ObservationLog()
  let consumer = Task { for await value in stream { await log.append(value) } }
  try await eventually { await log.snapshot().count == 1 }
  #expect(await log.snapshot() == [.readable(ContentDigest(original))])
  // Unrelated parent events and equal-byte inode replacements do not imply external changes.
  try Data("unrelated".utf8).write(to: fixture.directory.appendingPathComponent("other"))
  try original.write(to: fixture.file, options: .atomic)
  await monitor.refresh()
  try await Task.sleep(for: .milliseconds(100))
  #expect(await log.snapshot().count == 1)
  let changed = Data("# changed\n".utf8)
  try changed.write(to: fixture.file, options: .atomic)
  try await eventually { await log.snapshot().last == .readable(ContentDigest(changed)) }
  // The watch must still work after the first replacement.
  try original.write(to: fixture.file, options: .atomic)
  try await eventually { await log.snapshot().count == 3 }
  try FileManager.default.removeItem(at: fixture.file)
  try await eventually { await log.snapshot().last == .unreadable(.unavailable) }
  try changed.write(to: fixture.file)
  try await eventually { await log.snapshot().last == .readable(ContentDigest(changed)) }
  await monitor.stop()
  await consumer.value
}

@Test func monitorRejectsUnsafeAndOversizedFilesAndRecovers() async throws {
  let fixture = try MonitorFixture()
  defer { fixture.cleanup() }
  let monitor = SystemFileMonitor(directory: fixture.directory)
  let log = ObservationLog()
  let stream = try await monitor.start()
  let consumer = Task { for await value in stream { await log.append(value) } }
  try await eventually { await log.snapshot().last == .unreadable(.unavailable) }
  let other = fixture.directory.appendingPathComponent("target")
  try Data("# private".utf8).write(to: other)
  try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: other)
  await monitor.refresh()
  #expect(await log.snapshot().allSatisfy { if case .unreadable = $0 { true } else { false } })
  try FileManager.default.removeItem(at: fixture.file)
  try FileManager.default.linkItem(at: other, to: fixture.file)
  await monitor.refresh()
  try await eventually { await log.snapshot().last == .unreadable(.unsafeFile) }
  try FileManager.default.removeItem(at: fixture.file)
  try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: fixture.file)
  await monitor.refresh()
  try await eventually { await log.snapshot().last == .unreadable(.tooLarge) }
  let valid = Data("# recovered".utf8)
  try valid.write(to: fixture.file, options: .atomic)
  try await eventually { await log.snapshot().last == .readable(ContentDigest(valid)) }
  await monitor.stop()
  await consumer.value
}

@Test func monitorSubscriptionReplacementAndCancellation() async throws {
  let fixture = try MonitorFixture()
  defer { fixture.cleanup() }
  let bytes = Data("# fixture".utf8)
  try bytes.write(to: fixture.file)
  let monitor = SystemFileMonitor(directory: fixture.directory)
  let old = try await monitor.start()
  let current = try await monitor.start()
  var previous = old.makeAsyncIterator()
  _ = await previous.next()  // Previously buffered initial observation may still be delivered.
  #expect(await previous.next() == nil)
  var iterator = current.makeAsyncIterator()
  #expect(await iterator.next() == .readable(ContentDigest(bytes)))
  await monitor.refresh()
  await monitor.stop()
  #expect(await iterator.next() == nil)
}

@Test func observationsNeverResolvePendingTransactionsOrInventReceipts() {
  let digest = ContentDigest(Data("# fixture".utf8))
  let other = ContentDigest(Data("# external".utf8))
  #expect(
    SystemFileObservation.readable(digest).status(appliedDigest: digest, hasPendingApply: false)
      == .confirmed)
  #expect(
    SystemFileObservation.readable(other).status(appliedDigest: digest, hasPendingApply: false)
      == .externalChange)
  #expect(
    SystemFileObservation.readable(digest).status(appliedDigest: nil, hasPendingApply: false)
      == .unconfirmed)
  for value in [
    SystemFileObservation.readable(digest), .readable(other), .unreadable(.unavailable),
  ] {
    #expect(value.status(appliedDigest: digest, hasPendingApply: true) == .recoveryRequired)
  }
  #expect(
    SystemFileObservation.unreadable(.unavailable).status(
      appliedDigest: digest, hasPendingApply: false) == .unconfirmed)
}

@Test func monitorDebouncesBurstsAndReadsInPlaceEdits() async throws {
  let fixture = try MonitorFixture()
  defer { fixture.cleanup() }
  try Data("# initial".utf8).write(to: fixture.file)
  let monitor = SystemFileMonitor(directory: fixture.directory, debounce: .milliseconds(100))
  let stream = try await monitor.start()
  let log = ObservationLog()
  let consumer = Task { for await value in stream { await log.append(value) } }
  try await eventually { await log.snapshot().count == 1 }
  for index in 0..<20 {
    try Data("# revision \(index)".utf8).write(to: fixture.file)
  }
  let final = ContentDigest(Data("# revision 19".utf8))
  try await eventually { await log.snapshot().last == .readable(final) }
  #expect(await log.snapshot().count == 2)
  await monitor.stop()
  await consumer.value
}

@Test func monitorReportsLostDirectoryUntilExplicitRestart() async throws {
  let fixture = try MonitorFixture()
  defer { fixture.cleanup() }
  let original = Data("# original".utf8)
  try original.write(to: fixture.file)
  let monitor = SystemFileMonitor(directory: fixture.directory)
  let stream = try await monitor.start()
  let log = ObservationLog()
  let consumer = Task { for await value in stream { await log.append(value) } }
  try await eventually { await log.snapshot().count == 1 }
  let moved = fixture.directory.appendingPathComponent("../moved-" + UUID().uuidString)
    .standardizedFileURL
  try FileManager.default.moveItem(at: fixture.directory, to: moved)
  try await eventually { await log.snapshot().last == .unreadable(.watchUnavailable) }
  try FileManager.default.moveItem(at: moved, to: fixture.directory)
  await monitor.refresh()
  #expect(await log.snapshot().last == .unreadable(.watchUnavailable))
  var restarted = try await monitor.start().makeAsyncIterator()
  #expect(await restarted.next() == .readable(ContentDigest(original)))
  await monitor.stop()
  await consumer.value
}
