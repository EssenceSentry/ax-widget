import Foundation

/// Track append-only question events independently of the bounded prose tail.
/// A long tool output must not erase an unanswered question from the widget.
enum QuestionJournal {
  private struct Cursor {
    var inode: UInt64
    var offset: UInt64 = 0
    var buffer = Data()
    var dropping = false
    var tracker = QuestionTracker()
    var touched = Date()
  }
  private static let lock = NSLock()
  private static var cursors: [String: Cursor] = [:]
  private static let markers = [
    "request_user_input", "AskUserQuestion", "send_user_message_question_reply",
    "function_call_output", "tool_result",
  ].map { Data($0.utf8) }

  static func pending(_ url: URL) throws -> [AgentQuestionGroup] {
    lock.lock()
    defer { lock.unlock() }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    var cursor = cursors[url.path] ?? Cursor(inode: inode)
    if cursor.inode != inode || cursor.offset > size { cursor = Cursor(inode: inode) }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    try file.seek(toOffset: cursor.offset)
    while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
      cursor.offset += UInt64(chunk.count)
      cursor.buffer.append(chunk)
      while let newline = cursor.buffer.firstIndex(of: 10) {
        let record = cursor.buffer.prefix(upTo: newline)
        if !cursor.dropping { consume(Data(record), tracker: &cursor.tracker) }
        cursor.buffer.removeSubrange(...newline)
        cursor.dropping = false
      }
      if cursor.buffer.count > 8_388_608 {
        cursor.buffer.removeAll(keepingCapacity: true)
        cursor.dropping = true
      }
    }
    // Local test fixtures and a writer between its JSON and newline writes can
    // end in a complete record. Consume only if the complete JSON is valid.
    if !cursor.dropping, !cursor.buffer.isEmpty,
      let row = (try? JSONSerialization.jsonObject(with: cursor.buffer)) as? [String: Any]
    {
      cursor.tracker.consume(row)
      cursor.buffer.removeAll(keepingCapacity: true)
    }
    cursor.touched = Date()
    cursors[url.path] = cursor
    if cursors.count > 64,
      let oldest = cursors.min(by: { $0.value.touched < $1.value.touched })?.key
    {
      cursors.removeValue(forKey: oldest)
    }
    return cursor.tracker.pending
  }

  private static func consume(_ data: Data, tracker: inout QuestionTracker) {
    guard markers.contains(where: { data.range(of: $0) != nil }),
      let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return }
    tracker.consume(row)
  }
}
