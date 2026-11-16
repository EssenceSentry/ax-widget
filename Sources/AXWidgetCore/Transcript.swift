import Foundation

public struct TranscriptUpdate: Equatable {
  public var text = ""
  public var date: Date?
  public var activityDate: Date?
  public var needsInput = false
  public var questions: [AgentQuestionGroup] = []
  public init() {}
}

public enum TranscriptReader {
  public static func isMainConversation(_ url: URL, registeredDesktop: Bool = false) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 32_768)) ?? Data()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(8) {
      guard let data = String(line).data(using: .utf8),
        let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { continue }
      if row["type"] as? String == "user", let entrypoint = row["entrypoint"] as? String {
        if row["isSidechain"] as? Bool == true { return false }
        if let kind = row["sessionKind"] as? String, kind != "interactive" { return false }
        if registeredDesktop && entrypoint == "sdk-cli" { return true }
        return [
          "cli", "claude-vscode", "claude-code-vscode", "claude-desktop", "desktop", "vscode",
        ].contains(entrypoint)
      }
      guard row["type"] as? String == "session_meta", let payload = row["payload"] as? [String: Any]
      else { continue }
      if payload["thread_source"] as? String == "guardian_review" { return false }
      if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
        return false
      }
      if let source = payload["source"] as? String, source.contains("guardian") { return false }
      return true
    }
    return true
  }

  /// Only the recent bounded tail is read. Incomplete streaming records are ignored.
  public static func read(_ url: URL, maxBytes: Int = 1_048_576) throws -> TranscriptUpdate {
    guard url.pathExtension == "jsonl" else { return TranscriptUpdate() }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let offset = size > maxBytes ? size - UInt64(maxBytes) : 0
    try handle.seek(toOffset: offset)
    let data = try handle.readToEnd() ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    if offset > 0, !lines.isEmpty { lines.removeFirst() }
    var update = parse(lines.map(String.init))
    update.questions = try QuestionJournal.pending(url)
    update.needsInput = !update.questions.isEmpty
    return update
  }

  public static func parse(_ lines: [String]) -> TranscriptUpdate {
    var update = TranscriptUpdate()
    var tracker = QuestionTracker()
    for line in lines {
      guard let data = line.data(using: .utf8),
        let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { continue }
      tracker.consume(row)
      let type = row["type"] as? String
      let payload = row["payload"] as? [String: Any] ?? [:]
      let stamp = parseDate(row["timestamp"])
      if isConversationActivity(row), let stamp,
        update.activityDate.map({ stamp > $0 }) ?? true
      {
        update.activityDate = stamp
      }
      var text: String?
      if type == "response_item" {
        if payload["type"] as? String == "message", payload["role"] as? String == "assistant",
          payload["phase"] as? String != "analysis"
        {
          text = textBlocks(payload["content"])
        }
      } else if type == "event_msg", payload["type"] as? String == "agent_message" {
        text = payload["message"] as? String
      } else if type == "assistant", let message = row["message"] as? [String: Any] {
        text = textBlocks(message["content"])
      }
      if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        update.text = String(text.prefix(12_000))
        update.date = stamp
      }
    }
    update.questions = tracker.pending
    update.needsInput = !update.questions.isEmpty
    return update
  }

  private static func isConversationActivity(_ row: [String: Any]) -> Bool {
    let type = row["type"] as? String ?? ""
    let payload = row["payload"] as? [String: Any] ?? [:]
    if type == "response_item" {
      let kind = payload["type"] as? String ?? ""
      if kind == "message" {
        return ["user", "assistant"].contains(payload["role"] as? String ?? "")
      }
      return kind == "reasoning" || kind.hasSuffix("_call") || kind.hasSuffix("_call_output")
    }
    if type == "event_msg" {
      return [
        "user_message", "agent_message", "agent_reasoning", "task_started", "task_complete",
        "turn_aborted", "exec_command_begin", "exec_command_end", "exec_command_output_delta",
      ].contains(payload["type"] as? String ?? "")
    }
    // Opening a chat can update settings, usage and other bookkeeping records.
    // Only actual Claude messages and running-tool progress count as activity.
    return ["user", "assistant", "progress"].contains(type) && row["isMeta"] as? Bool != true
  }

  private static func textBlocks(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    let blocks = value as? [[String: Any]] ?? []
    let strings = blocks.compactMap { block -> String? in
      guard ["text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
      return block["text"] as? String
    }
    return strings.isEmpty ? nil : strings.joined(separator: "\n\n")
  }
}

public func parseDate(_ value: Any?) -> Date? {
  if let number = value as? Double {
    return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
  }
  guard let text = value as? String else { return nil }
  if let number = Double(text) { return parseDate(number) }
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = formatter.date(from: text) { return date }
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: text)
}
