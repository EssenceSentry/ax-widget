import Foundation

public struct LocalPaths: Sendable {
  public var axData: URL
  public var codexHome: URL
  public var claudeHome: URL
  public var claudeDesktop: URL

  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, axData: URL? = nil) {
    self.axData = axData ?? home.appendingPathComponent(".local/share/ax")
    self.codexHome = home.appendingPathComponent(".codex")
    self.claudeHome = home.appendingPathComponent(".claude")
    self.claudeDesktop = home.appendingPathComponent(
      "Library/Application Support/Claude/claude-code-sessions")
  }
}

public struct LocalRepository {
  public var paths: LocalPaths
  public init(paths: LocalPaths = LocalPaths()) { self.paths = paths }

  public func conversations(limit: Int = 8, at date: Date = Date(), pins: [ConversationPin] = [])
    -> (
      items: [Conversation], issues: [String], aliases: ClaudeSessionAliases
    )
  {
    let cutoff = date.addingTimeInterval(-12 * 3600)
    var found: [String: Conversation] = [:]
    let records = desktopRecords()
    let aliases = ClaudeSessionAliases(records: records, paths: paths)
    let saved = WidgetConversationPins(pins: pins.map(aliases.resolve))
    let pinnedIDs = Set(saved.pins.map(\.id))
    for pin in saved.pins where pin.provider == .claude { found[pin.id] = pin.conversation }
    var issues: [String] = []
    var excluded: Set<String> = []
    var codexHasSource = false
    let catalog = paths.axData.appendingPathComponent("catalog.sqlite3")
    if FileManager.default.fileExists(atPath: catalog.path) {
      do {
        let db = try ReadOnlyDatabase(url: catalog)
        for row in try db.rows("SELECT * FROM conversations WHERE provider='claude' ORDER BY mtime DESC LIMIT 40") {
          guard let provider = Provider(rawValue: row["provider"] ?? ""), let id = row["id"],
            UUID(uuidString: id) != nil
          else { continue }
          let item = Conversation(
            provider: provider, sessionID: id, title: row["title"] ?? "Untitled",
            project: row["project"] ?? "", source: row["source"],
            updated: parseDate(row["updated"]) ?? .distantPast)
          if aliases.key(item.id) == item.id { found[item.id] = item }
        }
      } catch { issues.append("ax conversation index: \(error.localizedDescription)") }
    }
    do {
      if let history = try CodexHistory(home: paths.codexHome) {
        codexHasSource = history.hasSource
        let pins = saved.pins.filter { $0.provider == .codex }.map(\.sessionID)
        for row in try history.recent(pins: pins) {
          guard let id = row["id"], UUID(uuidString: id) != nil else { continue }
          let key = "codex:" + id
          found[key] = Conversation(
            provider: .codex, sessionID: id, title: history.names[id] ?? row["title"] ?? "Codex conversation",
            project: row["cwd"] ?? "", source: row["rollout_path"],
            updated: parseDate(row["updated_at"]) ?? .distantPast)
        }
      }
    } catch { issues.append("Codex history: \(error.localizedDescription)") }

    for record in records {
      guard let id = record["cliSessionId"] as? String, UUID(uuidString: id) != nil else {
        continue
      }
      let key = "claude:\(id)"
      if record["isArchived"] as? Bool == true {
        excluded.insert(key)
        continue
      }
      let cwd = record["cwd"] as? String ?? ""
      let encoded = cwd.replacingOccurrences(
        of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
      var item =
        found[key]
        ?? Conversation(
          provider: .claude, sessionID: id,
          title: record["title"] as? String ?? "Claude conversation", project: cwd,
          source: paths.claudeHome.appendingPathComponent("projects/\(encoded)/\(id).jsonl").path,
          updated: parseDate(record["lastActivityAt"] ?? record["createdAt"]) ?? .distantPast)
      item.desktopSessionID = record["sessionId"] as? String
      if let title = record["title"] as? String, !title.isEmpty { item.title = title }
      if let date = parseDate(record["lastActivityAt"]), date > item.updated { item.updated = date }
      found[key] = item
    }

    var progress: [String: TaskProgress] = [:]
    var jobActivity: [String: Date] = [:]
    do {
      let rows =
        try DaemonClient.request("task.list", dataDirectory: paths.axData) as? [[String: Any]] ?? []
      for row in rows {
        guard let rawOwner = row["owner"] as? String else { continue }
        let owner = aliases.key(rawOwner)
        if let activity = parseDate(row["updated"]) {
          jobActivity[owner] = max(jobActivity[owner] ?? .distantPast, activity)
          if activity > found[owner]?.updated ?? .distantPast { found[owner]?.updated = activity }
        }
        var job = TaskProgress(
          done: row["done"] as? Double, total: row["total"] as? Double,
          unit: row["unit"] as? String, stage: row["stage"] as? String, runningCount: 1)
        if row["kind"] as? String == "run", let id = row["id"] as? String,
          AttachCommand.isTaskID(id)
        {
          job.attachableIDs = [id]
        }
        if progress[owner] != nil {
          progress[owner]?.include(job)
        } else {
          progress[owner] = job
        }
      }
    } catch { issues.append("ax tasks: \(error.localizedDescription)") }

    // Filter SDK workers before limiting candidates: many recent worker sessions
    // must not crowd older, real conversations out of the widget.
    let candidates = found.values.filter { item in
      guard !excluded.contains(item.id) else { return false }
      let modified = item.source.flatMap {
        try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
      }
      guard
        item.updated >= cutoff || pinnedIDs.contains(item.id)
          || modified.map({ $0 >= cutoff }) == true
      else { return false }
      if item.provider == .codex && codexHasSource { return true }
      return item.source.map {
        TranscriptReader.isMainConversation(
          URL(fileURLWithPath: $0), registeredDesktop: item.desktopSessionID != nil)
      }
        ?? true
    }
    .sorted {
      if pinnedIDs.contains($0.id) != pinnedIDs.contains($1.id) { return pinnedIDs.contains($0.id) }
      return $0.updated > $1.updated
    }
    var items: [Conversation] = []
    for var item in candidates {
      // Provider metadata is a discovery hint, not proof of conversation activity.
      // Codex bumps updated_at when an existing chat merely applies window settings.
      item.updated = jobActivity[item.id] ?? .distantPast
      item.progress = progress[item.id]
      if let source = item.source {
        do {
          let update = try TranscriptReader.read(URL(fileURLWithPath: source))
          item.latestUpdate = update.text
          item.updateAt = update.date
          if let activity = update.activityDate, activity > item.updated { item.updated = activity }
          item.needsAttention = update.needsInput
          item.questions = update.questions
        } catch {
          // Missing or compressed source is visible as an unavailable update, never fabricated.
          item.latestUpdate = ""
        }
      }
      if item.updated >= cutoff || pinnedIDs.contains(item.id) { items.append(item) }
    }
    return (saved.ordered(items, limit: limit), issues, aliases)
  }

  func desktopRecords() -> [[String: Any]] {
    let manager = FileManager.default
    var rows: [[String: Any]] = []
    guard
      let accounts = try? manager.contentsOfDirectory(
        at: paths.claudeDesktop, includingPropertiesForKeys: nil)
    else { return [] }
    for account in accounts
    where (try? account.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      for org in (try? manager.contentsOfDirectory(at: account, includingPropertiesForKeys: nil))
        ?? [] where (try? org.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      {
        for file in (try? manager.contentsOfDirectory(at: org, includingPropertiesForKeys: nil))
          ?? []
        where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
          if let data = try? Data(contentsOf: file), data.count < 1_048_576,
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
          {
            rows.append(value)
          }
        }
      }
    }
    return rows
  }
}
