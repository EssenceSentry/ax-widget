import Foundation

/// Claude can replace a CLI transcript while keeping the same Desktop chat.
/// Follow only explicit native lineage; matching titles never establish identity.
public struct ClaudeSessionAliases: Sendable {
  private var replacements: [String: ConversationPin] = [:]

  public init(records: [[String: Any]] = [], paths: LocalPaths = LocalPaths()) {
    let registered = records.compactMap { row -> (String, String, [String: Any])? in
      guard let id = row["cliSessionId"] as? String, UUID(uuidString: id) != nil,
        let desktop = row["sessionId"] as? String,
        desktop.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
      else { return nil }
      return (id, desktop, row)
    }
    let currentIDs = Set(registered.map { $0.0 })
    var candidates: [String: [ConversationPin]] = [:]
    for (id, desktop, row) in registered {
      let cwd = row["cwd"] as? String ?? ""
      let encoded = cwd.replacingOccurrences(
        of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
      let pin = ConversationPin(
        Conversation(
          provider: .claude, sessionID: id, title: row["title"] as? String ?? "Claude conversation",
          project: cwd,
          source: cwd.isEmpty
            ? nil : paths.claudeHome.appendingPathComponent("projects/\(encoded)/\(id).jsonl").path,
          updated: .distantPast, desktopSessionID: desktop))
      for previous in row["priorCliSessionIds"] as? [String] ?? []
      where UUID(uuidString: previous) != nil && !currentIDs.contains(previous) {
        candidates[previous, default: []].append(pin)
      }
    }
    for (previous, targets) in candidates {
      guard Set(targets.map(\.sessionID)).count == 1,
        Set(targets.compactMap(\.desktopSessionID)).count == 1
      else { continue }
      replacements[previous] = targets.first
    }
  }

  public func resolve(_ pin: ConversationPin) -> ConversationPin {
    guard pin.provider == .claude, var current = replacements[pin.sessionID] else { return pin }
    if current.source == nil, let source = pin.source,
      URL(fileURLWithPath: source).pathExtension == "jsonl"
    {
      current.source =
        URL(fileURLWithPath: source).deletingLastPathComponent()
        .appendingPathComponent(current.sessionID + ".jsonl").path
    }
    if current.title.isEmpty { current.title = pin.title }
    return current
  }

  public func key(_ key: String) -> String {
    guard key.hasPrefix("claude:"), let current = replacements[String(key.dropFirst(7))]
    else { return key }
    return current.id
  }
}
