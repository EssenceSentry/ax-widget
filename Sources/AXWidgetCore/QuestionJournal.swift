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
  private static let requestMarkers = [
    "request_user_input", "AskUserQuestion", "send_user_message_question_reply",
  ].map { Data($0.utf8) }
  private static let boundaryMarkers = ["task_started", "turn_aborted"].map { Data($0.utf8) }

  static func pending(_ url: URL) throws -> [AgentQuestionGroup] {
    lock.lock()
    defer { lock.unlock() }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var cursor = cursors[url.path] ?? Cursor(inode: inode)
    if cursor.inode != inode || cursor.offset > size { cursor = Cursor(inode: inode) }
    if cursor.offset == 0 { cursor.offset = try latestTurnOffset(file, size: size) }
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
    let isBoundary = boundaryMarkers.contains { data.range(of: $0) != nil }
    let isRequest = requestMarkers.contains { data.range(of: $0) != nil }
    // Ordinary tool output is often enormous. Only decode a result if it can
    // actually belong to a pending synchronous question.
    let isResult =
      !isBoundary && !isRequest
      && tracker.pending.contains { group in
        group.kind != .codexAsync && data.range(of: Data(group.id.utf8)) != nil
      }
    guard isBoundary || isRequest || isResult,
      let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return }
    tracker.consume(row)
  }

  /// Codex questions belong to the turn that asked them. Find its boundary
  /// backwards using cheap byte checks, rather than replaying years of history.
  private static func latestTurnOffset(_ file: FileHandle, size: UInt64) throws -> UInt64 {
    try file.seek(toOffset: 0)
    let header = try file.read(upToCount: 65_536) ?? Data()
    guard let first = header.split(separator: 10).first,
      let row = (try? JSONSerialization.jsonObject(with: Data(first))) as? [String: Any],
      row["type"] as? String == "session_meta"
    else { return 0 }
    var end = size
    var carry = Data()
    while end > 0 {
      let start = end > 524_288 ? end - 524_288 : 0
      try file.seek(toOffset: start)
      var chunk = try file.read(upToCount: Int(end - start)) ?? Data()
      chunk.append(carry)
      let lines = chunk.split(separator: 10, omittingEmptySubsequences: false)
      let complete = start == 0 ? lines[...] : lines.dropFirst()
      for line in complete.reversed() {
        guard line.count < 4096 else { continue }
        let data = Data(line)
        guard boundaryMarkers.contains(where: { data.range(of: $0) != nil }),
          let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          row["type"] as? String == "event_msg",
          let payload = row["payload"] as? [String: Any],
          let event = payload["type"] as? String,
          ["task_started", "turn_aborted"].contains(event)
        else { continue }
        return start + UInt64(line.startIndex - chunk.startIndex)
      }
      // A turn-boundary record is tiny. A partial huge tool record can be
      // discarded; retaining a zero byte prevents it becoming valid JSON.
      if let first = lines.first, first.count < 4096 {
        carry = Data(first)
      } else {
        carry = Data([0])
      }
      end = start
    }
    return 0
  }
}
