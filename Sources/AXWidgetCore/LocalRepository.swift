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
      items: [Conversation], issues: [String]
    )
  {
    let cutoff = date.addingTimeInterval(-12 * 3600)
    var found: [String: Conversation] = [:]
    let saved = WidgetConversationPins(pins: pins)
    let pinnedIDs = Set(saved.pins.map(\.id))
    for pin in saved.pins { found[pin.id] = pin.conversation }
    var issues: [String] = []
    var excluded: Set<String> = []
    let catalog = paths.axData.appendingPathComponent("catalog.sqlite3")
    if FileManager.default.fileExists(atPath: catalog.path) {
      do {
        let db = try ReadOnlyDatabase(url: catalog)
        for row in try db.rows("SELECT * FROM conversations ORDER BY mtime DESC LIMIT 40") {
          guard let provider = Provider(rawValue: row["provider"] ?? ""), let id = row["id"],
            UUID(uuidString: id) != nil
          else { continue }
          let item = Conversation(
            provider: provider, sessionID: id, title: row["title"] ?? "Untitled",
            project: row["project"] ?? "", source: row["source"],
            updated: parseDate(row["updated"]) ?? .distantPast)
          found[item.id] = item
        }
      } catch { issues.append("ax conversation index: \(error.localizedDescription)") }
    }
    do {
      let dbFiles = try FileManager.default.contentsOfDirectory(
        at: paths.codexHome, includingPropertiesForKeys: nil
      )
      .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
      }
      if let file = dbFiles.first {
        let db = try ReadOnlyDatabase(url: file)
        let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
        let originColumns = ["source", "originator"].filter { columns.contains($0) }
        let extras = originColumns.isEmpty ? "" : "," + originColumns.joined(separator: ",")
        for archived in try db.rows("SELECT id FROM threads WHERE archived=1") {
          if let id = archived["id"] { excluded.insert("codex:" + id) }
        }
        let selectedPins = saved.pins.filter { $0.provider == .codex }.map(\.sessionID)
        let pinnedRows =
          selectedPins.isEmpty
          ? []
          : try db.rows(
            "SELECT id,title,cwd,rollout_path,updated_at,archived" + extras
              + " FROM threads WHERE id IN (" + selectedPins.map { _ in "?" }.joined(separator: ",")
              + ")",
            strings: selectedPins)
        for row in try db.rows(
          "SELECT id,title,cwd,rollout_path,updated_at,archived" + extras
            + " FROM threads ORDER BY updated_at DESC LIMIT 60") + pinnedRows
        {
          guard let id = row["id"], UUID(uuidString: id) != nil else { continue }
          let key = "codex:\(id)"
          let origin = originColumns.compactMap { row[$0] }.joined(separator: " ").lowercased()
          if row["archived"] == "1" || origin.contains("guardian") || origin.contains("subagent") {
            excluded.insert(key)
            continue
          }
          found[key] = Conversation(
            provider: .codex, sessionID: id, title: row["title"] ?? "Codex conversation",
            project: row["cwd"] ?? "", source: row["rollout_path"],
            updated: parseDate(row["updated_at"]) ?? .distantPast)
        }
      }
    } catch { issues.append("Codex history: \(error.localizedDescription)") }

    for record in desktopRecords() {
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
        guard let owner = row["owner"] as? String else { continue }
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

    let titlesURL = paths.codexHome.appendingPathComponent("session_index.jsonl")
    if let data = try? Data(contentsOf: titlesURL), data.count < 4_194_304 {
      for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        if let data = String(line).data(using: .utf8),
          let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let id = row["id"] as? String, let title = row["thread_name"] as? String
        {
          found["codex:" + id]?.title = title
        }
      }
    }
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
    return (saved.ordered(items, limit: limit), issues)
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
