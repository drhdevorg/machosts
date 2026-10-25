/// The production writer stays unavailable while Gate 0 is deferred.
/// There is deliberately no filesystem or authorization operation in this bootstrap.
public enum SystemWriter {
  public enum Failure: Error, Equatable, Sendable {
    case integrationUnavailable
  }

  public static func apply() throws {
    throw Failure.integrationUnavailable
  }
}
