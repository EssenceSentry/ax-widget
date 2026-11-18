import Foundation

/// The local thread registry supplies the same interactive source kinds as Codex's chat list.
struct CodexHistory {
  static let interactiveSources = ["cli", "vscode"]

  private let db: ReadOnlyDatabase
  private let interactive: String
  private let columns: Set<String>
  private var visible: String {
    columns.contains("archived") ? interactive + " AND archived=0" : interactive
  }
  let names: [String: String]
  let hasSource: Bool

  init?(home: URL) throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: home, includingPropertiesForKeys: nil)
    guard
      let file = files.filter({
        $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite"
      })
      .max(by: {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      })
    else { return nil }
    db = try ReadOnlyDatabase(url: file)
    columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
    hasSource = columns.contains("source")
    var predicates: [String] = []
    if hasSource {
      let sources = Self.interactiveSources.map { "'\($0)'" }.joined(separator: ",")
      predicates.append("source IN (\(sources))")
    }
    if columns.contains("thread_source") {
      predicates.append("COALESCE(thread_source, '') NOT IN ('guardian_review', 'subagent')")
    }
    if columns.contains("originator") {
      predicates.append("COALESCE(originator, '') NOT LIKE '%guardian%'")
      predicates.append("COALESCE(originator, '') NOT LIKE '%subagent%'")
    }
    interactive = predicates.isEmpty ? "1" : predicates.joined(separator: " AND ")

    let index = home.appendingPathComponent("session_index.jsonl")
    var titles: [String: String] = [:]
    if let data = try? Data(contentsOf: index), data.count <= 4_194_304 {
      for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        if let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let id = row["id"] as? String, let title = row["thread_name"] as? String
        {
          titles[id] = title
        }
      }
    }
    names = titles
  }

  func recent(pins: [String]) throws -> [[String: String]] {
    let select = "SELECT id,title,cwd,rollout_path,updated_at FROM threads WHERE " + visible
    // Older registries need transcript classification. A burst of workers must not consume the limit.
    var rows = try db.rows(select + " ORDER BY updated_at DESC" + (hasSource ? " LIMIT 60" : ""))
    let included = Set(rows.compactMap { $0["id"] })
    let extra = pins.filter { !included.contains($0) }
    if !extra.isEmpty {
      let placeholders = extra.map { _ in "?" }.joined(separator: ",")
      rows += try db.rows(select + " AND id IN (" + placeholders + ")", strings: extra)
    }
    return rows
  }

  func uniqueTitle(for id: String) throws -> String? {
    var fields = ["id", "title"]
    if columns.contains("archived") { fields.append("archived") }
    if !hasSource && columns.contains("rollout_path") { fields.append("rollout_path") }
    let rows = try db.rows(
      "SELECT " + fields.joined(separator: ",") + " FROM threads WHERE " + interactive)
    guard let target = rows.first(where: { $0["id"] == id }), target["archived"] != "1",
      let title = names[id] ?? target["title"], !title.isEmpty
    else { return nil }
    // An archived interactive chat can still have a native window with the same title.
    let matches = rows.filter { row in
      guard let key = row["id"], (names[key] ?? row["title"]) == title else { return false }
      return row["rollout_path"].map {
        TranscriptReader.isMainConversation(URL(fileURLWithPath: $0))
      } ?? true
    }
    return matches.count == 1 && matches.first?["id"] == id ? title : nil
  }
}
