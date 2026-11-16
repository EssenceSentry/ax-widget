import Foundation

/// Codex's Electron document URL is app://-/index.html for every conversation.
/// Its window title is usable only when native history maps it to exactly one session.
public enum CodexWindowIdentity {
  public static func title(sessionID: String, home: URL = LocalPaths().codexHome) -> String? {
    guard UUID(uuidString: sessionID) != nil else { return nil }
    do {
      let files = try FileManager.default.contentsOfDirectory(
        at: home, includingPropertiesForKeys: nil
      )
      .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
      }
      guard let file = files.first else { return nil }
      let db = try ReadOnlyDatabase(url: file)
      var titles: [String: String] = [:]
      for row in try db.rows("SELECT id,title FROM threads") {
        if let id = row["id"], let title = row["title"] { titles[id] = title }
      }
      let index = home.appendingPathComponent("session_index.jsonl")
      if let data = try? Data(contentsOf: index), data.count <= 4_194_304 {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
          if let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
            let id = row["id"] as? String, let title = row["thread_name"] as? String
          {
            titles[id] = title
          }
        }
      }
      guard let title = titles[sessionID], !title.isEmpty,
        titles.values.filter({ $0 == title }).count == 1
      else { return nil }
      return title
    } catch { return nil }
  }
}
