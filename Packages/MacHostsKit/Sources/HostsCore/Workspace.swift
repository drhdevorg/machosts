import CryptoKit
import Foundation

public struct ContentDigest: Hashable, Codable, Sendable {
  public let hex: String
  public init(_ data: Data) {
    hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard value.count == 64,
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid SHA-256 digest")
    }
    hex = value
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(hex)
  }
}

public struct Profile: Identifiable, Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case local, remote }
  public let id: UUID
  public var name: String
  public var folderID: UUID?
  public var kind: Kind
  public var source: String
  public var isEnabled: Bool
  public var revision: UInt64

  public init(
    id: UUID = UUID(), name: String, folderID: UUID? = nil, kind: Kind = .local,
    source: String = "", isEnabled: Bool = false, revision: UInt64 = 0
  ) {
    self.id = id
    self.name = name
    self.folderID = folderID
    self.kind = kind
    self.source = source
    self.isEnabled = isEnabled
    self.revision = revision
  }

  /// Requires the digest used to render the editor's line controls, even if a caller forgot to bump revision.
  public mutating func toggleLine(_ number: Int, expectedDigest: ContentDigest) throws {
    guard kind == .local else { throw WorkspaceFailure.readOnlyProfile }
    let data = Data(source.utf8)
    guard ContentDigest(data) == expectedDigest else { throw WorkspaceFailure.staleRevision }
    let document = HostsDocument.parse(data, context: .profile)
    guard let line = document.lines.first(where: { $0.number == number }),
      case .entry(let entry) = line.kind
    else {
      throw WorkspaceFailure.notAnEntry
    }
    guard revision < UInt64.max else { throw WorkspaceFailure.revisionOverflow }
    let replacement =
      entry.isEnabled
      ? HostsSyntax.disabled + line.content
      : String(line.content.dropFirst(HostsSyntax.disabled.count))
    var result = data
    result.replaceSubrange(line.bytes, with: Data((replacement + line.ending).utf8))
    guard result.count <= HostsLimits.profileBytes else { throw WorkspaceFailure.limitExceeded }
    source = String(decoding: result, as: UTF8.self)
    revision += 1
  }
}

public struct ProfileFolder: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var parentID: UUID?
  public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
    self.id = id
    self.name = name
    self.parentID = parentID
  }
}

public struct TrashedProfile: Codable, Equatable, Sendable {
  public let profile: Profile
  public let deletedAt: Date
  public let formerIndex: Int
  public init(profile: Profile, deletedAt: Date = Date(), formerIndex: Int) {
    self.profile = profile
    self.deletedAt = deletedAt
    self.formerIndex = formerIndex
  }
}

public enum WorkspaceFailure: Error, Equatable, Sendable {
  case unsupportedSchema, staleRevision, revisionOverflow, limitExceeded, duplicateID
  case invalidFolder, invalidName, missingProfile, readOnlyProfile, notAnEntry
}

public struct Workspace: Codable, Equatable, Sendable {
  public static let currentSchema = 1
  public var schemaVersion: Int
  public var revision: UInt64
  /// Array order is the stable composition/sidebar order; folders never imply activation.
  public var profiles: [Profile]
  public var folders: [ProfileFolder]
  public var trash: [TrashedProfile]

  public init(
    revision: UInt64 = 0, profiles: [Profile] = [], folders: [ProfileFolder] = [],
    trash: [TrashedProfile] = []
  ) {
    schemaVersion = Self.currentSchema
    self.revision = revision
    self.profiles = profiles
    self.folders = folders
    self.trash = trash
  }

  public func validate() throws {
    guard schemaVersion == Self.currentSchema else { throw WorkspaceFailure.unsupportedSchema }
    guard profiles.count + trash.count <= HostsLimits.profiles else {
      throw WorkspaceFailure.limitExceeded
    }
    let ids = profiles.map(\.id) + trash.map(\.profile.id) + folders.map(\.id)
    guard Set(ids).count == ids.count else { throw WorkspaceFailure.duplicateID }
    let folderIDs = Set(folders.map(\.id))
    for profile in profiles + trash.map(\.profile) {
      guard Self.validName(profile.name) else { throw WorkspaceFailure.invalidName }
      guard profile.source.utf8.count <= HostsLimits.profileBytes else {
        throw WorkspaceFailure.limitExceeded
      }
    }
    for profile in profiles {
      if let id = profile.folderID, !folderIDs.contains(id) { throw WorkspaceFailure.invalidFolder }
    }
    let parents = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.parentID) })
    for folder in folders {
      guard Self.validName(folder.name) else { throw WorkspaceFailure.invalidName }
      var seen: Set<UUID> = [folder.id]
      var parent = folder.parentID
      while let id = parent {
        guard folderIDs.contains(id), seen.insert(id).inserted,
          seen.count <= HostsLimits.folderDepth
        else {
          throw WorkspaceFailure.invalidFolder
        }
        parent = parents[id] ?? nil
      }
    }
  }

  public static func validName(_ name: String) -> Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 200
      && !name.unicodeScalars.contains {
        $0.value < 32 || (127...159).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029
      }
      && !name.contains(HostsSyntax.begin) && !name.contains(HostsSyntax.end)
  }

  public func encoded() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    guard data.count <= HostsLimits.workspaceBytes else { throw WorkspaceFailure.limitExceeded }
    return data
  }

  public mutating func deleteProfile(_ id: UUID, now: Date = Date()) throws {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else {
      throw WorkspaceFailure.missingProfile
    }
    guard revision < UInt64.max else { throw WorkspaceFailure.revisionOverflow }
    trash.append(.init(profile: profiles.remove(at: index), deletedAt: now, formerIndex: index))
    revision += 1
  }

  public mutating func restoreProfile(_ id: UUID) throws {
    guard let index = trash.firstIndex(where: { $0.profile.id == id }) else {
      throw WorkspaceFailure.missingProfile
    }
    guard revision < UInt64.max else { throw WorkspaceFailure.revisionOverflow }
    let item = trash.remove(at: index)
    var profile = item.profile
    profile.isEnabled = false
    if !folders.contains(where: { $0.id == profile.folderID }) { profile.folderID = nil }
    profiles.insert(profile, at: max(0, min(item.formerIndex, profiles.count)))
    revision += 1
  }
}
