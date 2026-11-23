import Foundation

public enum AxClient {
  public static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL?
  {
    let candidates = [
      home.appendingPathComponent(".local/bin/ax"), URL(fileURLWithPath: "/opt/homebrew/bin/ax"),
      URL(fileURLWithPath: "/usr/local/bin/ax"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  public static func usage(executable: URL) throws -> [Allowance] {
    try usageReport(executable: executable, refreshClaude: false).allowances
  }

  public static func usageReport(executable: URL, refreshClaude: Bool) throws
    -> (allowances: [Allowance], claudeError: String?)
  {
    let process = Process()
    process.executableURL = executable
    process.arguments = refreshClaude ? ["usage", "--refresh"] : ["usage"]
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ax-widget-" + UUID().uuidString)
    FileManager.default.createFile(
      atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let output = try FileHandle(forWritingTo: file)
    defer {
      try? output.close()
      try? FileManager.default.removeItem(at: file)
    }
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    for name in ["CODEX_THREAD_ID", "CLAUDE_CODE_SESSION_ID", "AX_CALLER"] {
      environment.removeValue(forKey: name)
    }
    process.environment = environment
    try process.run()
    let deadline = Date().addingTimeInterval(refreshClaude ? 60 : 12)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
      process.terminate()
      let grace = Date().addingTimeInterval(0.5)
      while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw ClientError.timeout
    }
    let data = try Data(contentsOf: file)
    guard data.count <= 2_097_152 else { throw ClientError.invalid }
    guard process.terminationStatus == 0 else { throw ClientError.unavailable }
    return try decodeReport(data)
  }

  public static func decodeUsage(_ data: Data) throws -> [Allowance] {
    try decodeReport(data).allowances
  }

  private static func decodeReport(_ data: Data) throws
    -> (allowances: [Allowance], claudeError: String?)
  {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let windows = object["windows"] as? [[String: Any]]
    else { throw ClientError.invalid }
    let allowances: [Allowance] = windows.compactMap { row in
      guard let provider = Provider(rawValue: row["provider"] as? String ?? ""),
        let name = row["name"] as? String
      else { return nil }
      // JSON booleans are NSNumber too; they are not valid usage percentages.
      let used = (row["used"] as? NSNumber).flatMap {
        String(cString: $0.objCType) == "c" ? nil : $0.doubleValue
      }
      return Allowance(
        provider: provider, name: name, used: used, observed: parseDate(row["observed"]),
        resets: parseDate(row["resets"]), status: row["status"] as? String ?? "unavailable")
    }
    return (allowances, object["claude_refresh_error"] as? String)
  }

  public static func needsClaudeRefresh(_ allowances: [Allowance], at now: Date) -> Bool {
    ["five_hour", "weekly_all"].contains { name in
      guard let row = allowances.first(where: { $0.provider == .claude && $0.name == name }),
        row.remaining(at: now) != nil, let observed = row.observed
      else { return true }
      return now.timeIntervalSince(observed) >= 210
        || (row.resets.map { $0.timeIntervalSince(now) < 65 } ?? false)
    }
  }
  public enum ClientError: LocalizedError {
    case timeout, unavailable, invalid
    public var errorDescription: String? {
      switch self {
      case .timeout: "ax usage timed out"
      case .unavailable: "ax usage is unavailable"
      case .invalid: "ax returned an unsupported usage snapshot"
      }
    }
  }
}
