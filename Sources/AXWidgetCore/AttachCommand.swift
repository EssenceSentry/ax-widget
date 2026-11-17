import Foundation

public enum AttachCommand {
  public enum Error: LocalizedError {
    case unavailable, invalidTask, creationFailed
    public var errorDescription: String? {
      switch self {
      case .unavailable: "Install ax and Terminal to reattach to a task."
      case .invalidTask: "The task ID is invalid."
      case .creationFailed: "Could not prepare the terminal command."
      }
    }
  }

  public static func isTaskID(_ id: String) -> Bool {
    id.utf8.count == 12 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  public static func write(id: String, executable: URL, config: String? = nil) throws -> URL {
    guard isTaskID(id) else { throw Error.invalidTask }
    func quote(_ text: String) -> String {
      "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("ax-\(UUID()).command")
    var script = "#!/bin/sh\n/bin/rm -f -- \"$0\"\n"
    if let config { script += "export AX_CONFIG=" + quote(config) + "\n" }
    script += "exec " + quote(executable.path) + " attach " + id + "\n"
    guard
      FileManager.default.createFile(
        atPath: file.path, contents: Data(script.utf8),
        attributes: [.posixPermissions: 0o700])
    else { throw Error.creationFailed }
    return file
  }
}
