import Foundation

public enum SnapshotStore {
  /// The extension receives read-only access to this one directory, not provider histories.
  public static var directory: URL {
    let uid = getuid()
    // NSHomeDirectory inside an extension points to its sandbox container.
    let home =
      getpwuid(uid).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home).appendingPathComponent(
      "Library/Application Support/ax-widget")
  }
  public static var file: URL { directory.appendingPathComponent("snapshot.json") }

  public static func save(_ snapshot: Snapshot, to file: URL = file) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(snapshot)
    try data.write(to: file, options: [.atomic])
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  public static func read(from file: URL = file) -> Snapshot {
    do {
      let data = try Data(contentsOf: file)
      guard data.count < 2_097_152 else { throw AxClient.ClientError.invalid }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      let snapshot = try decoder.decode(Snapshot.self, from: data)
      guard snapshot.schema == 1 else { throw AxClient.ClientError.invalid }
      return snapshot
    } catch {
      return Snapshot(issues: ["Open AX Widget to load local usage and conversations."])
    }
  }
}
