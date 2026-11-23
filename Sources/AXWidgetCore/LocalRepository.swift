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
    let visibleRecords = records.filter { $0["isArchived"] as? Bool != true }
    let claudeIDs = Array(Set(visibleRecords.compactMap { $0["cliSessionId"] as? String }))
    // Pins and ax supply titles and transcript locations. Only a current
    // Desktop registration can put a Claude conversation in the widget.
    var claudeDetails = Dictionary(uniqueKeysWithValues:
      saved.pins.filter { $0.provider == .claude }.map { ($0.id, $0.conversation) })
    var issues: [String] = []
    var codexHasSource = false
    let catalog = paths.axData.appendingPathComponent("catalog.sqlite3")
    if !claudeIDs.isEmpty, FileManager.default.fileExists(atPath: catalog.path) {
      do {
        let db = try ReadOnlyDatabase(url: catalog)
        for start in stride(from: 0, to: claudeIDs.count, by: 500) {
          let ids = Array(claudeIDs[start..<min(start + 500, claudeIDs.count)])
          let placeholders = ids.map { _ in "?" }.joined(separator: ",")
          let query = "SELECT id,title,project,source,updated FROM conversations WHERE provider='claude' AND id IN (\(placeholders))"
          for row in try db.rows(query, strings: ids) {
            guard let id = row["id"] else { continue }
            let item = Conversation(
              provider: .claude, sessionID: id, title: row["title"] ?? "Untitled",
              project: row["project"] ?? "", source: row["source"],
              updated: parseDate(row["updated"]) ?? .distantPast)
            claudeDetails[item.id] = item
          }
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

    for record in visibleRecords {
      guard let id = record["cliSessionId"] as? String, UUID(uuidString: id) != nil else {
        continue
      }
      let key = "claude:\(id)"
      let cwd = record["cwd"] as? String ?? ""
      let encoded = cwd.replacingOccurrences(
        of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
      var item =
        claudeDetails[key]
        ?? Conversation(
          provider: .claude, sessionID: id,
          title: record["title"] as? String ?? "Claude conversation", project: cwd,
          source: paths.claudeHome.appendingPathComponent("projects/\(encoded)/\(id).jsonl").path,
          updated: parseDate(record["lastActivityAt"] ?? record["createdAt"]) ?? .distantPast)
      item.desktopSessionID = record["sessionId"] as? String
      guard item.deepLink != nil else { continue }
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
    func directories(_ root: URL) -> [URL] {
      let entries = (try? manager.contentsOfDirectory(at: root,
        includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
      return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
    func object(_ url: URL) -> [String: Any]? {
      guard let data = try? Data(contentsOf: url), data.count < 8_388_608 else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func selected(_ folders: [URL], id: String?) -> URL? {
      if let id { return folders.first { $0.lastPathComponent == id } }
      return folders.count == 1 ? folders.first : nil
    }
    let config = paths.claudeDesktop.deletingLastPathComponent().appendingPathComponent("config.json")
    let accountID = object(config)?["lastKnownAccountUuid"] as? String
    guard let account = selected(directories(paths.claudeDesktop), id: accountID) else { return [] }
    let orgs = directories(account)
    var orgID: String?
    if orgs.count > 1 {
      let config = paths.claudeHome.deletingLastPathComponent().appendingPathComponent(".claude.json")
      let identity = object(config)?["oauthAccount"] as? [String: Any]
      if identity?["accountUuid"] as? String == account.lastPathComponent {
        orgID = identity?["organizationUuid"] as? String
      }
    }
    guard let org = selected(orgs, id: orgID),
      let entries = try? manager.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)
    else { return [] }
    let index = object(org.appendingPathComponent("archived-sessions.idx"))
    let archived = Set((index?["archived"] as? [String] ?? []).map {
      URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
    })
    let deleted = Set(entries.map(\.lastPathComponent).filter { $0.hasPrefix("deleted_") }
      .map { String($0.dropFirst("deleted_".count)) })
    return entries.compactMap { file in
      let nativeID = file.deletingPathExtension().lastPathComponent
      guard file.pathExtension == "json", nativeID.hasPrefix("local_"),
        var record = object(file), record["sessionId"] as? String == nativeID
      else { return nil }
      let suffix = String(nativeID.dropFirst("local_".count))
      if archived.contains(nativeID) || archived.contains(suffix) || deleted.contains(suffix)
        || (record["cliSessionId"] as? String).map(deleted.contains) == true
      {
        record["isArchived"] = true
      }
      return record
    }
  }
}
