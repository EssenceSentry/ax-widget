import CSQLite
import Foundation
import Testing

@testable import AXWidgetCore

private func activityLine(_ type: String, at date: Date, fields: [String: Any] = [:]) throws
  -> String
{
  var row = fields
  row["type"] = type
  row["timestamp"] = ISO8601DateFormatter().string(from: date)
  return String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self)
}

@Test func bookkeepingDoesNotRefreshActivityButMessagesAndToolsDo() throws {
  let old = Date(timeIntervalSince1970: 1_800_000_000)
  let recent = old.addingTimeInterval(72 * 3600)
  let prose = try activityLine(
    "event_msg", at: old,
    fields: [
      "payload": ["type": "agent_message", "message": "Original update"]
    ])
  let bookkeeping = try [
    activityLine("event_msg", at: recent, fields: ["payload": ["type": "thread_settings_applied"]]),
    activityLine("event_msg", at: recent, fields: ["payload": ["type": "token_count"]]),
    activityLine("session_meta", at: recent),
    activityLine("turn_context", at: recent),
    activityLine(
      "response_item", at: recent,
      fields: [
        "payload": ["type": "message", "role": "developer", "content": "Reloaded instructions"]
      ]),
    activityLine("system", at: recent),
    activityLine("user", at: recent, fields: ["isMeta": true]),
  ]
  let unchanged = TranscriptReader.parse([prose] + bookkeeping)
  #expect(unchanged.activityDate == old)
  #expect(unchanged.date == old)
  for event in try [
    activityLine(
      "response_item", at: recent,
      fields: [
        "payload": ["type": "message", "role": "user", "content": "Continue"]
      ]),
    activityLine("response_item", at: recent, fields: ["payload": ["type": "reasoning"]]),
    activityLine("response_item", at: recent, fields: ["payload": ["type": "custom_tool_call"]]),
    activityLine(
      "response_item", at: recent, fields: ["payload": ["type": "function_call_output"]]),
    activityLine("event_msg", at: recent, fields: ["payload": ["type": "task_started"]]),
    activityLine("user", at: recent, fields: ["message": ["content": "Continue"]]),
    activityLine(
      "assistant", at: recent,
      fields: [
        "message": ["content": [["type": "thinking", "thinking": "Not preview text"]]]
      ]),
    activityLine("progress", at: recent),
  ] {
    let update = TranscriptReader.parse([prose, event] + bookkeeping)
    #expect(update.activityDate == recent)
    #expect(update.text == "Original update")
    #expect(update.date == old)
  }
}

@Test func reopenedOldChatsStayOutAndRealActivityControlsOrderAndCutoff() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let old = now.addingTimeInterval(-72 * 3600)
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let paths = LocalPaths(home: home)
  try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  var writer: OpaquePointer?
  sqlite3_open(paths.codexHome.appendingPathComponent("state_5.sqlite").path, &writer)
  defer { sqlite3_close(writer) }
  sqlite3_exec(
    writer,
    "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,updated_at REAL,archived INT)",
    nil, nil, nil)
  func add(_ index: Int, metadata: Date, events: [String], missing: Bool = false) throws
    -> Conversation
  {
    let id = String(format: "11111111-1111-4111-8111-%012d", index)
    let source = home.appendingPathComponent(id + ".jsonl")
    if !missing {
      try events.joined(separator: "\n").write(to: source, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: source.path)
    }
    sqlite3_exec(
      writer,
      "INSERT INTO threads VALUES('\(id)','Chat \(index)','','\(source.path)',\(metadata.timeIntervalSince1970),0)",
      nil, nil, nil)
    return Conversation(
      provider: .codex, sessionID: id, title: "Chat \(index)", source: source.path,
      updated: metadata)
  }
  let oldProse = try activityLine(
    "event_msg", at: old, fields: ["payload": ["type": "agent_message", "message": "Old update"]])
  let opened = try activityLine(
    "event_msg", at: now, fields: ["payload": ["type": "thread_settings_applied"]])
  let stale = try add(1, metadata: now, events: [oldProse, opened])
  // A burst of reopened windows cannot crowd genuine recent activity out.
  for index in 10...40 { _ = try add(index, metadata: now, events: [oldProse, opened]) }
  let recent = try add(
    2, metadata: now,
    events: [
      activityLine(
        "event_msg", at: now.addingTimeInterval(-7200),
        fields: ["payload": ["type": "agent_message", "message": "Recent update"]])
    ])
  let user = try add(
    3, metadata: old,
    events: [
      oldProse,
      activityLine(
        "response_item", at: now.addingTimeInterval(-3600),
        fields: ["payload": ["type": "message", "role": "user", "content": "Continue"]]),
    ])
  let tool = try add(
    4, metadata: old,
    events: [
      oldProse,
      activityLine(
        "response_item", at: now.addingTimeInterval(-1800),
        fields: ["payload": ["type": "custom_tool_call_output", "output": "Still working"]]),
    ])
  let missing = try add(5, metadata: now, events: [], missing: true)

  let records = paths.claudeDesktop.appendingPathComponent("account/org")
  try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
  let claudeID = "22222222-2222-4222-8222-222222222222"
  let nativeID = "local_" + claudeID
  let source = paths.claudeHome.appendingPathComponent(
    "projects/-fixture-activity/\(claudeID).jsonl")
  try FileManager.default.createDirectory(
    at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
  try [
    activityLine(
      "user", at: old, fields: ["entrypoint": "cli", "message": ["content": "Old request"]]),
    activityLine("assistant", at: old, fields: ["message": ["content": "Old Claude update"]]),
  ].joined(separator: "\n").write(to: source, atomically: true, encoding: .utf8)
  try JSONSerialization.data(withJSONObject: [
    "cliSessionId": claudeID, "sessionId": nativeID, "title": "Old Claude",
    "cwd": "/fixture/activity", "lastActivityAt": now.timeIntervalSince1970,
  ]).write(to: records.appendingPathComponent(nativeID + ".json"))

  let repository = LocalRepository(paths: paths)
  let result = repository.conversations(at: now).items
  #expect(result.map(\.id) == [tool.id, user.id, recent.id])
  #expect(result.first?.latestUpdate == "Old update")
  #expect(result.first?.updated == now.addingTimeInterval(-1800))
  #expect(
    repository.conversations(at: now, pins: [ConversationPin(stale), ConversationPin(missing)])
      .items.map(\.id) == [stale.id, missing.id, tool.id, user.id, recent.id])
  #expect(repository.conversations(at: now.addingTimeInterval(12 * 3600 + 1)).items.isEmpty)
}
