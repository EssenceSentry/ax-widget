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
        self.claudeDesktop = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }
}

public struct LocalRepository {
    public var paths: LocalPaths
    public init(paths: LocalPaths = LocalPaths()) { self.paths = paths }

    public func conversations(limit: Int = 8) -> (items: [Conversation], issues: [String]) {
        var found: [String: Conversation] = [:]
        var issues: [String] = []
        var excluded: Set<String> = []
        let catalog = paths.axData.appendingPathComponent("catalog.sqlite3")
        if FileManager.default.fileExists(atPath: catalog.path) {
            do {
                let db = try ReadOnlyDatabase(url: catalog)
                for row in try db.rows("SELECT * FROM conversations ORDER BY mtime DESC LIMIT 40") {
                    guard let provider = Provider(rawValue: row["provider"] ?? ""), let id = row["id"], UUID(uuidString: id) != nil else { continue }
                    let item = Conversation(provider: provider, sessionID: id, title: row["title"] ?? "Untitled",
                                            project: row["project"] ?? "", source: row["source"], updated: parseDate(row["updated"]) ?? .distantPast)
                    found[item.id] = item
                }
            } catch { issues.append("ax conversation index: \(error.localizedDescription)") }
        }
        do {
            let dbFiles = try FileManager.default.contentsOfDirectory(at: paths.codexHome, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            if let file = dbFiles.first {
                let db = try ReadOnlyDatabase(url: file)
                for row in try db.rows("SELECT id,title,cwd,rollout_path,updated_at,archived FROM threads ORDER BY updated_at DESC LIMIT 40") {
                    guard let id = row["id"], UUID(uuidString: id) != nil else { continue }
                    let key = "codex:\(id)"
                    if row["archived"] == "1" { excluded.insert(key); continue }
                    found[key] = Conversation(provider: .codex, sessionID: id, title: row["title"] ?? "Codex conversation",
                                              project: row["cwd"] ?? "", source: row["rollout_path"], updated: parseDate(row["updated_at"]) ?? .distantPast)
                }
            }
        } catch { issues.append("Codex history: \(error.localizedDescription)") }

        for record in desktopRecords() {
            guard let id = record["cliSessionId"] as? String, UUID(uuidString: id) != nil else { continue }
            let key = "claude:\(id)"
            if record["isArchived"] as? Bool == true { excluded.insert(key); continue }
            let cwd = record["cwd"] as? String ?? ""
            let encoded = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
            var item = found[key] ?? Conversation(provider: .claude, sessionID: id,
                title: record["title"] as? String ?? "Claude conversation", project: cwd,
                source: paths.claudeHome.appendingPathComponent("projects/\(encoded)/\(id).jsonl").path,
                updated: parseDate(record["lastActivityAt"] ?? record["createdAt"]) ?? .distantPast)
            item.desktopSessionID = record["sessionId"] as? String
            if let title = record["title"] as? String, !title.isEmpty { item.title = title }
            if let date = parseDate(record["lastActivityAt"]), date > item.updated { item.updated = date }
            found[key] = item
        }

        var progress: [String: TaskProgress] = [:]
        do {
            let file = paths.axData.appendingPathComponent("core.sqlite3")
            if FileManager.default.fileExists(atPath: file.path) {
                let db = try ReadOnlyDatabase(url: file)
                for row in try db.rows("SELECT owner,done,total,unit,stage FROM tasks WHERE status IN ('starting','running') ORDER BY updated DESC") {
                    guard let owner = row["owner"] else { continue }
                    if progress[owner] != nil { progress[owner]?.runningCount += 1; continue }
                    progress[owner] = TaskProgress(done: row["done"].flatMap(Double.init), total: row["total"].flatMap(Double.init),
                                                   unit: row["unit"], stage: row["stage"], runningCount: 1)
                }
            }
        } catch { issues.append("ax tasks: \(error.localizedDescription)") }

        let candidates = found.values.filter { !excluded.contains($0.id) }
            .sorted {
                let a = progress[$0.id] != nil, b = progress[$1.id] != nil
                return a == b ? $0.updated > $1.updated : a
            }.prefix(24)
        var items: [Conversation] = []
        for var item in candidates {
            item.progress = progress[item.id]
            if let source = item.source {
                do {
                    let update = try TranscriptReader.read(URL(fileURLWithPath: source))
                    item.latestUpdate = update.text; item.updateAt = update.date
                    item.needsAttention = update.needsInput
                } catch {
                    // Missing or compressed source is visible as an unavailable update, never fabricated.
                    item.latestUpdate = ""
                }
            }
            items.append(item)
        }
        items.sort {
            let lhs = ($0.needsAttention ? 2 : 0) + (($0.progress?.runningCount ?? 0) > 0 ? 1 : 0)
            let rhs = ($1.needsAttention ? 2 : 0) + (($1.progress?.runningCount ?? 0) > 0 ? 1 : 0)
            return lhs == rhs ? $0.updated > $1.updated : lhs > rhs
        }
        return (Array(items.prefix(limit)), issues)
    }

    private func desktopRecords() -> [[String: Any]] {
        let manager = FileManager.default
        var rows: [[String: Any]] = []
        guard let accounts = try? manager.contentsOfDirectory(at: paths.claudeDesktop, includingPropertiesForKeys: nil) else { return [] }
        for account in accounts where account.hasDirectoryPath {
            for org in (try? manager.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] where org.hasDirectoryPath {
                for file in (try? manager.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    if let data = try? Data(contentsOf: file), data.count < 1_048_576,
                       let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { rows.append(value) }
                }
            }
        }
        return rows
    }
}
