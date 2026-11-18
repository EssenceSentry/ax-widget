import CSQLite
import Foundation
import Testing

@testable import AXWidgetCore

@Test func onlyRegisteredInteractiveCodexChatsReachTheWidget() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let paths = LocalPaths(home: home)
  defer { try? FileManager.default.removeItem(at: home) }
  for dir in [paths.codexHome, paths.axData] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  let now = Date()
  let stableID = { (n: Int) in String(format: "abcdef00-0000-4000-8000-%012d", n) }
  let transcript = home.appendingPathComponent("chat.jsonl")
  let message: [String: Any] = [
    "timestamp": ISO8601DateFormatter().string(from: now), "type": "event_msg",
    "payload": ["type": "agent_message", "message": "A visible update"],
  ]
  try JSONSerialization.data(withJSONObject: message).write(to: transcript)
  var writer: OpaquePointer?
  sqlite3_open(paths.codexHome.appendingPathComponent("state_5.sqlite").path, &writer)
  defer { sqlite3_close(writer) }
  func sql(_ statement: String) throws {
    try #require(sqlite3_exec(writer, statement, nil, nil, nil) == SQLITE_OK)
  }
  try sql(
    "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,updated_at REAL,archived INT,source TEXT,thread_source TEXT,originator TEXT)"
  )
  func add(_ n: Int, _ source: String, _ kind: String = "user", archived: Int = 0) throws {
    try sql(
      "INSERT INTO threads VALUES('\(stableID(n))','Title \(n)','','\(transcript.path)',\(now.timeIntervalSince1970 + Double(n)),\(archived),'\(source)','\(kind)','Codex Desktop')"
    )
  }
  try add(1, "cli")
  try add(2, "vscode", "agent_forked_thread")
  for n in 3...80 { try add(n, "exec") }
  try add(81, #"{"subagent":{"thread_spawn":{}}}"#)
  try add(82, "vscode", "guardian_review")
  try add(83, "vscode", archived: 1)
  try sql(
    "ATTACH DATABASE '\(paths.axData.appendingPathComponent("catalog.sqlite3").path)' AS catalog")
  try sql(
    "CREATE TABLE catalog.conversations(id TEXT, provider TEXT, title TEXT, project TEXT, source TEXT, updated REAL, mtime REAL)"
  )
  // Even an indexed, named and explicitly pinned transcript needs an eligible native registration.
  for n in [3, 84] {
    try sql(
      "INSERT INTO catalog.conversations VALUES('\(stableID(n))','codex','Catalog','','\(transcript.path)',\(now.timeIntervalSince1970),1)"
    )
  }
  let names = try [2, 3, 84].map { n in
    String(
      decoding: try JSONSerialization.data(withJSONObject: [
        "id": stableID(n), "thread_name": "Renamed chat",
      ]), as: UTF8.self)
  }
  try names.joined(separator: "\n").write(
    to: paths.codexHome.appendingPathComponent("session_index.jsonl"),
    atomically: true, encoding: .utf8)
  let pins = [2, 3, 83, 84].map { n in
    ConversationPin(
      Conversation(provider: .codex, sessionID: stableID(n), title: "Saved", updated: now))
  }
  let result = LocalRepository(paths: paths).conversations(at: now, pins: pins).items
  #expect(result.map(\.sessionID) == [stableID(2), stableID(1)])
  #expect(result.first?.title == "Renamed chat")
  #expect(
    CodexWindowIdentity.title(sessionID: stableID(2), home: paths.codexHome) == "Renamed chat")
  #expect(CodexWindowIdentity.title(sessionID: stableID(3), home: paths.codexHome) == nil)
  #expect(CodexWindowIdentity.title(sessionID: stableID(84), home: paths.codexHome) == nil)
  try sql("UPDATE threads SET title='Renamed chat' WHERE archived=1")
  #expect(CodexWindowIdentity.title(sessionID: stableID(2), home: paths.codexHome) == nil)
}

@Test func legacyCodexMetadataCanExceedTheFirstRead() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  let long = String(repeating: "x", count: 70_000)
  for (source, visible) in [("cli", true), ("vscode", true), ("exec", false), ("unknown", false)] {
    try
      #"{"type":"session_meta","payload":{"instructions":"\#(long)","source":"\#(source)","thread_source":"user"}}"#
      .write(to: file, atomically: true, encoding: .utf8)
    #expect(TranscriptReader.isMainConversation(file) == visible)
  }
}
