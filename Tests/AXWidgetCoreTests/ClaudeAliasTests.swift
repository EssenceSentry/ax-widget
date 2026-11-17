import CSQLite
import Foundation
import Testing

@testable import AXWidgetCore

private let formerID = "11111111-1111-4111-8111-111111111111"
private let currentID = "22222222-2222-4222-8222-222222222222"
private let otherID = "33333333-3333-4333-8333-333333333333"

private func registration(_ id: String, desktop: String, prior: [String] = []) -> [String: Any] {
  [
    "cliSessionId": id, "sessionId": desktop, "priorCliSessionIds": prior,
    "cwd": "/fixture/project", "title": "Same title", "lastActivityAt": 1_800_000_000,
  ]
}

@Test func claudeAliasesFollowExplicitLineageAndPreserveSavedSelectionsAndJobOwners() {
  let aliases = ClaudeSessionAliases(records: [
    registration(currentID, desktop: "local_current", prior: [formerID])
  ])
  let old = ConversationPin(
    Conversation(
      provider: .claude, sessionID: formerID, title: "Old title",
      source: "/old/path/\(formerID).jsonl", updated: .distantPast,
      desktopSessionID: "local_current"))
  let resolved = aliases.resolve(old)
  #expect(resolved.sessionID == currentID)
  #expect(resolved.desktopSessionID == "local_current")
  #expect(resolved.source?.hasSuffix("/\(currentID).jsonl") == true)
  #expect(resolved.title == "Same title")
  #expect(aliases.key(old.id) == resolved.id)
  #expect(aliases.key("codex:" + formerID) == "codex:" + formerID)
  let saved = WidgetConversationPins(pins: [old, resolved].map(aliases.resolve))
  #expect(saved.pins == [resolved])
  let group = ConversationGroup(pins: [old].map(aliases.resolve))
  #expect(group.pins == [resolved])
}

@Test func ambiguousOrIndependentlyRegisteredSessionsAreNotMerged() {
  let first = registration(currentID, desktop: "local_current", prior: [formerID, "invalid"])
  let second = registration(otherID, desktop: "local_other", prior: [formerID])
  #expect(
    ClaudeSessionAliases(records: [first, second]).key("claude:" + formerID) == "claude:" + formerID
  )
  let independent = registration(formerID, desktop: "local_separate")
  #expect(
    ClaudeSessionAliases(records: [first, independent]).key("claude:" + formerID) == "claude:"
      + formerID)
  #expect(ClaudeSessionAliases(records: [first]).key("claude:invalid") == "claude:invalid")
}

@Test func continuedClaudeChatAppearsOnceWhileSeparateSameTitleChatRemains() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let paths = LocalPaths(home: home)
  defer { try? FileManager.default.removeItem(at: home) }
  let folder = paths.claudeDesktop.appendingPathComponent("account/org")
  let project = paths.claudeHome.appendingPathComponent("projects/-fixture-project")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: paths.axData, withIntermediateDirectories: true)
  var writer: OpaquePointer?
  sqlite3_open(paths.axData.appendingPathComponent("catalog.sqlite3").path, &writer)
  defer { sqlite3_close(writer) }
  sqlite3_exec(
    writer,
    "CREATE TABLE conversations(provider TEXT,id TEXT,title TEXT,project TEXT,source TEXT,updated REAL,mtime REAL)",
    nil, nil, nil)
  for (id, message) in [
    (formerID, "Old transcript"), (currentID, "Current transcript"), (otherID, "Separate chat"),
  ] {
    let file = project.appendingPathComponent(id + ".jsonl")
    let row: [String: Any] = [
      "type": "assistant", "timestamp": ISO8601DateFormatter().string(from: now),
      "message": ["content": [["type": "text", "text": message]]],
    ]
    try JSONSerialization.data(withJSONObject: row).write(to: file)
    sqlite3_exec(
      writer,
      "INSERT INTO conversations VALUES('claude','\(id)','Same title','','\(file.path)',\(now.timeIntervalSince1970),\(now.timeIntervalSince1970))",
      nil, nil, nil)
  }
  let record = registration(currentID, desktop: "local_current", prior: [formerID])
  try JSONSerialization.data(withJSONObject: record).write(
    to: folder.appendingPathComponent("local_current.json"))
  try JSONSerialization.data(withJSONObject: registration(otherID, desktop: "local_other")).write(
    to: folder.appendingPathComponent("local_other.json"))
  let old = ConversationPin(
    Conversation(
      provider: .claude, sessionID: formerID, title: "Same title",
      source: project.appendingPathComponent(formerID + ".jsonl").path, updated: now,
      desktopSessionID: "local_current"))
  let current = ConversationPin(
    Conversation(
      provider: .claude, sessionID: currentID, title: "Same title", updated: now,
      desktopSessionID: "local_current"))
  let result = LocalRepository(paths: paths).conversations(at: now, pins: [old, current])
  #expect(result.items.count == 2)
  #expect(Set(result.items.map(\.sessionID)) == [currentID, otherID])
  #expect(result.items.first?.sessionID == currentID)
  #expect(result.items.first?.latestUpdate == "Current transcript")
  #expect(result.items.first?.source?.hasSuffix("/\(currentID).jsonl") == true)
  #expect(result.aliases.resolve(old).sessionID == currentID)
  #expect(result.items.filter { $0.title == "Same title" }.count == 2)
}

@Test func widgetOrderingNeverRepeatsAnExactIDAndKeepsTheNewestCopy() {
  let now = Date()
  let old = Conversation(
    provider: .codex, sessionID: formerID, title: "Old", updated: now.addingTimeInterval(-10))
  let new = Conversation(provider: .codex, sessionID: formerID, title: "New", updated: now)
  let other = Conversation(
    provider: .claude, sessionID: formerID, title: "Separate provider", updated: now)
  let saved = WidgetConversationPins(pins: [ConversationPin(old)])
  let result = saved.ordered([old, new, other, other], limit: 8)
  #expect(result.map(\.id) == [new.id, other.id])
  #expect(result.first?.title == "New")
}
