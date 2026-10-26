import Foundation
import HostsCore

public enum WorkspaceExchangeFailure: Error, Equatable, Sendable {
  case invalidDocument, unsupportedVersion
}

/// Portable source snapshots, deliberately separate from durable app/recovery schemas.
/// Remote profiles become local cached copies; no URL, activation, trash or receipt travels.
public struct WorkspaceExchangeDocument: Encodable, Sendable {
  public static let currentVersion = 1
  public let format: String
  public let version: Int
  public let folders: [ProfileFolder]
  public let profiles: [SourceProfile]

  public struct SourceProfile: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let folderID: UUID?
    public let source: String
  }

  public init(workspace: Workspace) throws {
    _ = try workspace.encoded()
    for profile in workspace.profiles { _ = try HostsTextImport(data: Data(profile.source.utf8)) }
    format = "MacHosts"
    version = Self.currentVersion
    folders = workspace.folders
    profiles = workspace.profiles.map {
      SourceProfile(id: $0.id, name: $0.name, folderID: $0.folderID, source: $0.source)
    }
  }

  public init(data: Data) throws {
    guard data.count <= HostsLimits.workspaceBytes else { throw HostsTextExchangeFailure.sizeLimit }
    do {
      let header = try JSONDecoder().decode(Header.self, from: data)
      guard header.format == "MacHosts" else { throw WorkspaceExchangeFailure.invalidDocument }
      guard header.version == Self.currentVersion else {
        throw WorkspaceExchangeFailure.unsupportedVersion
      }
      let payload = try JSONDecoder().decode(Payload.self, from: data)
      format = header.format
      version = header.version
      folders = payload.folders
      profiles = payload.profiles
      _ = try validatedWorkspace().encoded()
      for profile in profiles { _ = try HostsTextImport(data: Data(profile.source.utf8)) }
    } catch let error as WorkspaceExchangeFailure {
      throw error
    } catch let error as HostsTextExchangeFailure {
      throw error
    } catch {
      throw WorkspaceExchangeFailure.invalidDocument
    }
  }

  private struct Payload: Decodable {
    let folders: [ProfileFolder]
    let profiles: [SourceProfile]
  }

  private struct Header: Decodable {
    let format: String
    let version: Int
  }

  private func validatedWorkspace() -> Workspace {
    Workspace(
      profiles: profiles.map {
        Profile(id: $0.id, name: $0.name, folderID: $0.folderID, source: $0.source)
      }, folders: folders)
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(self)
    // Export must always be accepted by the same version's importer, without truncation.
    guard data.count <= HostsLimits.workspaceBytes else { throw HostsTextExchangeFailure.sizeLimit }
    return data
  }

  /// Selects a subset of a validated review without changing source order or identities.
  /// Required ancestor folders travel with selected profiles; callers may also retain
  /// every folder, including empty ones. Unknown selections fail rather than vanish.
  public func selecting(
    profileIDs: Set<UUID>, includeAllFolders: Bool
  ) throws -> WorkspaceExchangeDocument {
    guard profileIDs.isSubset(of: Set(profiles.map(\.id))) else {
      throw WorkspaceExchangeFailure.invalidDocument
    }
    let selectedProfiles = profiles.filter { profileIDs.contains($0.id) }
    var folderIDs = includeAllFolders ? Set(folders.map(\.id)) : Set<UUID>()
    let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    for profile in selectedProfiles {
      var ancestor = profile.folderID
      while let id = ancestor, folderIDs.insert(id).inserted {
        ancestor = byID[id]?.parentID
      }
    }
    return WorkspaceExchangeDocument(
      folders: folders.filter { folderIDs.contains($0.id) }, profiles: selectedProfiles)
  }

  private init(folders: [ProfileFolder], profiles: [SourceProfile]) {
    format = "MacHosts"
    version = Self.currentVersion
    self.folders = folders
    self.profiles = profiles
  }

  /// Current workspace validation (including trash and serialized byte budgets) is
  /// performed before publication. Imported identifiers never address existing objects.
  public func appending(to workspace: Workspace) throws -> Workspace {
    var result = workspace
    var used = Set(
      workspace.profiles.map(\.id) + workspace.trash.map { $0.profile.id }
        + workspace.folders.map(\.id))
    var identities: [UUID: UUID] = [:]
    for id in folders.map(\.id) + profiles.map(\.id) {
      var fresh = UUID()
      while !used.insert(fresh).inserted { fresh = UUID() }
      identities[id] = fresh
    }
    result.folders += try folders.map {
      guard let id = identities[$0.id] else { throw WorkspaceExchangeFailure.invalidDocument }
      return ProfileFolder(
        id: id, name: $0.name,
        parentID: $0.parentID.flatMap { identities[$0] })
    }
    result.profiles += try profiles.map {
      guard let id = identities[$0.id] else { throw WorkspaceExchangeFailure.invalidDocument }
      return Profile(
        id: id, name: $0.name,
        folderID: $0.folderID.flatMap { identities[$0] }, source: $0.source)
    }
    _ = try result.encoded()
    return result
  }
}

public actor WorkspaceExchange {
  private let files = HostsTextExchange()
  public init() {}

  public func inspect(_ source: String) throws -> HostsTextImport {
    try HostsTextImport(data: Data(source.utf8))
  }

  public func capture(_ workspace: Workspace) throws -> WorkspaceExchangeDocument {
    try WorkspaceExchangeDocument(workspace: workspace)
  }

  public func read(_ url: URL) async throws -> WorkspaceExchangeDocument {
    try await WorkspaceExchangeDocument(
      data: files.readData(url, limit: HostsLimits.workspaceBytes))
  }

  public func writeNew(_ document: WorkspaceExchangeDocument, to url: URL) async throws {
    let data = try document.encoded()
    try await files.writeNewData(data, to: url, limit: HostsLimits.workspaceBytes)
  }
}
