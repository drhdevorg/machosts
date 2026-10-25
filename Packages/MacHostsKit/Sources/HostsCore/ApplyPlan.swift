import Foundation

public struct EntryOrigin: Equatable, Sendable {
  public let profileID: UUID?
  public let line: Int
}

public struct ComposedMapping: Equatable, Sendable {
  public let hostname: String
  public let address: IPAddress
  public let origins: [EntryOrigin]
}

public struct HostsConflict: Equatable, Sendable {
  public let hostname: String
  public let family: IPAddress.Family
  public let mappings: [ComposedMapping]
}

public struct PlanDiagnostic: Equatable, Sendable {
  public let profileID: UUID?
  public let diagnostic: HostsDiagnostic
}

public enum PlanFailure: Error, Equatable, Sendable {
  case invalidWorkspace(WorkspaceFailure)
  case invalidDocuments([PlanDiagnostic])
  case conflicts([HostsConflict])
  case managedBlockChanged
  case invalidManagedReplacement
  case resultLimitExceeded
}

/// Evidence of the separator introduced by an append. Only usable for these exact system bytes.
/// Persist it with the confirmed applied snapshot, never infer ownership from a trailing newline.
public struct ManagedSeparatorEvidence: Codable, Equatable, Sendable {
  public let systemDigest: ContentDigest
  public let blockStart: Int
  public let separator: Data
  public init(systemDigest: ContentDigest, blockStart: Int, separator: Data) {
    self.systemDigest = systemDigest
    self.blockStart = blockStart
    self.separator = separator
  }
}

public struct ApplyPlan: Sendable {
  public enum Operation: Sendable { case noChange, replaceManagedBlock, removeManagedBlock }
  public let id: UUID
  public let workspaceRevision: UInt64
  public let workspaceDigest: ContentDigest
  public let sourceDigests: [UUID: ContentDigest]
  public let expectedSystemDigest: ContentDigest
  public let previousManagedDigest: ContentDigest?
  public let resultingSystemDigest: ContentDigest
  public let operation: Operation
  public let before: Data
  public let after: Data
  public let activeProfileIDs: [UUID]
  public let mappings: [ComposedMapping]
  public let added: [ComposedMapping]
  public let removed: [ComposedMapping]
  public let separatorEvidence: ManagedSeparatorEvidence?

  public func isCurrent(workspace: Workspace, system: Data) throws -> Bool {
    let digest = ContentDigest(try workspace.encoded())
    return workspaceRevision == workspace.revision
      && workspaceDigest == digest && expectedSystemDigest == ContentDigest(system)
  }

  /// Pure planning only. The future writer must revalidate against freshly read bytes.
  public static func prepare(
    workspace: Workspace, system: Data, expectedManagedDigest: ContentDigest? = nil,
    separatorEvidence: ManagedSeparatorEvidence? = nil
  ) throws -> ApplyPlan {
    let system = Data(system)
    let workspaceData: Data
    do { workspaceData = try workspace.encoded() } catch let failure as WorkspaceFailure {
      throw PlanFailure.invalidWorkspace(failure)
    }
    let document = HostsDocument.parse(system, context: .system)
    var diagnostics = document.diagnostics.map { PlanDiagnostic(profileID: nil, diagnostic: $0) }
    let active = workspace.profiles.filter(\.isEnabled)
    var parsed: [(Profile, HostsDocument)] = []
    for profile in active {
      let parsedDocument = HostsDocument.parse(Data(profile.source.utf8), context: .profile)
      parsed.append((profile, parsedDocument))
      diagnostics += parsedDocument.diagnostics.map { .init(profileID: profile.id, diagnostic: $0) }
    }
    guard diagnostics.isEmpty else { throw PlanFailure.invalidDocuments(diagnostics) }
    let oldBlock = document.managedBlock.map { system.subdata(in: $0) }
    let oldDigest = oldBlock.map(ContentDigest.init)
    if let expectedManagedDigest, expectedManagedDigest != oldDigest {
      throw PlanFailure.managedBlockChanged
    }

    var allMappings = MappingAccumulator()
    for line in document.lines
    where !(document.managedBlock?.contains(line.bytes.lowerBound) ?? false) {
      if case .entry(let entry) = line.kind, entry.isEnabled {
        appendMappings(entry, origin: .init(profileID: nil, line: line.number), to: &allMappings)
      }
    }
    var ownMappings = MappingAccumulator()
    var outputLines: [String] = []
    var emitted: Set<MappingKey> = []
    for (profile, parsedDocument) in parsed {
      var profileLines: [String] = []
      for line in parsedDocument.lines {
        switch line.kind {
        case .entry(let entry) where entry.isEnabled:
          let origin = EntryOrigin(profileID: profile.id, line: line.number)
          appendMappings(entry, origin: origin, to: &allMappings)
          appendMappings(entry, origin: origin, to: &ownMappings)
          let names = entry.hostnames.filter {
            emitted.insert(.init(hostname: $0, address: entry.address)).inserted
          }
          if !names.isEmpty {
            var generated = entry.address.canonical + " " + names.joined(separator: " ")
            if let comment = entry.comment { generated += " #" + comment }
            profileLines.append(generated)
          }
        case .comment:
          profileLines.append(line.content)
        default: break
        }
      }
      // Empty/disabled profiles alone do not leave an empty owned block behind.
      if !profileLines.isEmpty {
        outputLines.append("# Profile: " + profile.name)
        outputLines += profileLines
      }
    }
    let conflicts = findConflicts(allMappings.values)
    guard conflicts.isEmpty else { throw PlanFailure.conflicts(conflicts) }
    let generated: Data
    if outputLines.isEmpty {
      generated = Data()
    } else {
      generated = Data(
        ([HostsSyntax.begin] + outputLines + [HostsSyntax.end, ""]).joined(separator: "\n").utf8)
    }
    let replacement = try Self.replacingManagedBlock(
      in: system, with: generated, separatorEvidence: separatorEvidence)
    let result = replacement.data
    let afterDigest = ContentDigest(result)
    var oldMappings = MappingAccumulator()
    for line in document.lines where document.managedBlock?.contains(line.bytes.lowerBound) ?? false
    {
      if case .entry(let entry) = line.kind, entry.isEnabled {
        appendMappings(entry, origin: .init(profileID: nil, line: line.number), to: &oldMappings)
      }
    }
    let oldKeys = Set(
      oldMappings.values.map { MappingKey(hostname: $0.hostname, address: $0.address) })
    let newKeys = Set(
      ownMappings.values.map { MappingKey(hostname: $0.hostname, address: $0.address) })
    return ApplyPlan(
      id: UUID(), workspaceRevision: workspace.revision,
      workspaceDigest: ContentDigest(workspaceData),
      sourceDigests: Dictionary(
        uniqueKeysWithValues: workspace.profiles.map {
          ($0.id, ContentDigest(Data($0.source.utf8)))
        }),
      expectedSystemDigest: ContentDigest(system), previousManagedDigest: oldDigest,
      resultingSystemDigest: afterDigest,
      operation: result == system
        ? .noChange : (generated.isEmpty ? .removeManagedBlock : .replaceManagedBlock),
      before: system, after: result, activeProfileIDs: active.map(\.id),
      mappings: ownMappings.values,
      added: ownMappings.values.filter {
        !oldKeys.contains(.init(hostname: $0.hostname, address: $0.address))
      },
      removed: oldMappings.values.filter {
        !newKeys.contains(.init(hostname: $0.hostname, address: $0.address))
      },
      separatorEvidence: replacement.separatorEvidence)
  }

  /// Revalidates an isolated generated block against fresh system bytes. No caller-supplied
  /// prefix/suffix is accepted. Separator evidence must come from a trusted prior transaction.
  public static func replacingManagedBlock(
    in system: Data, with generated: Data,
    separatorEvidence: ManagedSeparatorEvidence? = nil
  ) throws -> ManagedBlockReplacement {
    let system = Data(system)
    let document = HostsDocument.parse(system, context: .system)
    guard document.diagnostics.isEmpty else {
      throw PlanFailure.invalidDocuments(
        document.diagnostics.map {
          .init(profileID: nil, diagnostic: $0)
        })
    }
    if !generated.isEmpty {
      let block = HostsDocument.parse(generated, context: .system)
      guard block.diagnostics.isEmpty, block.managedBlock == 0..<generated.count,
        block.lines.allSatisfy({ $0.ending == "\n" }),
        !block.lines.contains(where: { $0.content.hasPrefix(HostsSyntax.disabled) })
      else { throw PlanFailure.invalidManagedReplacement }
    }
    var result = system
    var introducedSeparator = Data()
    var blockStart: Int?
    if let range = document.managedBlock {
      var replacement = generated
      if !replacement.isEmpty {
        // If a foreign suffix follows immediately, preserve the delimiter's original terminator.
        if let last = document.lines.last(where: { $0.bytes.upperBound == range.upperBound }),
          last.ending != "\n"
        {
          replacement.removeLast()
          replacement.append(Data(last.ending.utf8))
        }
      }
      var replacementRange = range
      if let evidence = validEvidence(separatorEvidence, system: system, block: range) {
        if generated.isEmpty {
          replacementRange = (range.lowerBound - evidence.separator.count)..<range.upperBound
        } else {
          introducedSeparator = evidence.separator
        }
      }
      result.replaceSubrange(replacementRange, with: replacement)
      if !generated.isEmpty { blockStart = range.lowerBound }
    } else if !generated.isEmpty {
      if let last = system.last, last != 10 && last != 13 { introducedSeparator = Data([10]) }
      result.append(introducedSeparator)
      blockStart = result.count
      result.append(generated)
    }
    guard result.count <= HostsLimits.systemBytes else { throw PlanFailure.resultLimitExceeded }
    let resultDocument = HostsDocument.parse(result, context: .system)
    guard resultDocument.diagnostics.isEmpty else { throw PlanFailure.resultLimitExceeded }
    // Recheck conflicts including foreign active entries at the file boundary.
    var mappings = MappingAccumulator()
    for line in resultDocument.lines {
      if case .entry(let entry) = line.kind, entry.isEnabled {
        appendMappings(entry, origin: .init(profileID: nil, line: line.number), to: &mappings)
      }
    }
    let conflicts = findConflicts(mappings.values)
    guard conflicts.isEmpty else { throw PlanFailure.conflicts(conflicts) }
    let digest = ContentDigest(result)
    return ManagedBlockReplacement(
      data: result,
      separatorEvidence: blockStart.map {
        .init(systemDigest: digest, blockStart: $0, separator: introducedSeparator)
      })
  }

  private struct MappingKey: Hashable {
    let hostname: String
    let address: IPAddress
  }

  private struct MappingAccumulator {
    var order: [MappingKey] = []
    var origins: [MappingKey: [EntryOrigin]] = [:]
    var values: [ComposedMapping] {
      order.map { .init(hostname: $0.hostname, address: $0.address, origins: origins[$0] ?? []) }
    }

    mutating func append(_ entry: HostsEntry, origin: EntryOrigin) {
      for hostname in entry.hostnames {
        let key = MappingKey(hostname: hostname, address: entry.address)
        if origins[key] == nil { order.append(key) }
        if origins[key]?.last != origin { origins[key, default: []].append(origin) }
      }
    }
  }

  private static func appendMappings(
    _ entry: HostsEntry, origin: EntryOrigin, to mappings: inout MappingAccumulator
  ) {
    mappings.append(entry, origin: origin)
  }

  private static func findConflicts(_ mappings: [ComposedMapping]) -> [HostsConflict] {
    struct Key: Hashable {
      let hostname: String
      let family: IPAddress.Family
    }
    var order: [Key] = []
    var groups: [Key: [ComposedMapping]] = [:]
    for mapping in mappings {
      let key = Key(hostname: mapping.hostname, family: mapping.address.family)
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(mapping)
    }
    return order.compactMap { key in
      guard let group = groups[key], group.count > 1 else { return nil }
      return .init(hostname: key.hostname, family: key.family, mappings: group)
    }
  }

  private static func validEvidence(
    _ evidence: ManagedSeparatorEvidence?, system: Data, block: Range<Int>
  ) -> ManagedSeparatorEvidence? {
    guard let evidence, evidence.systemDigest == ContentDigest(system),
      evidence.blockStart == block.lowerBound,
      evidence.separator == Data([10]), block.lowerBound >= 1,
      system.subdata(in: (block.lowerBound - 1)..<block.lowerBound) == evidence.separator
    else { return nil }
    return evidence
  }
}

/// Pure result shared by planning and independent transaction revalidation.
public struct ManagedBlockReplacement: Sendable {
  public let data: Data
  public let separatorEvidence: ManagedSeparatorEvidence?
}
