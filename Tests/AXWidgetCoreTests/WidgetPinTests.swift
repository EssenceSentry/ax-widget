import CSQLite
import Foundation
import Testing

@testable import AXWidgetCore

private func savedChat(_ index: Int, date: Date) -> Conversation {
  Conversation(
    provider: .codex, sessionID: String(format: "33333333-3333-4333-8333-%012d", index),
    title: "Saved chat \(index)", updated: date, latestUpdate: "Private message never saved")
}

@Test func widgetPinsHaveNoWindowLimitOrDesktopRegistrationRequirement() throws {
  let now = Date()
  var saved = WidgetConversationPins()
  for index in 1...10 { saved.add(savedChat(index, date: now)) }
  saved.add(savedChat(1, date: now))
  var claude = savedChat(11, date: now)
  claude.provider = .claude
  #expect(claude.deepLink == nil)
  saved.add(claude)
  #expect(saved.pins.count == 11)
  var invalid = savedChat(12, date: now)
  invalid.sessionID = "invalid?prompt=do-something"
  saved.add(invalid)
  #expect(saved.pins.count == 11)
  let data = try JSONEncoder().encode(saved.pins)
  #expect(!String(decoding: data, as: UTF8.self).contains("Private message never saved"))
  #expect(WidgetConversationPins(saved: data) == saved)
  var group = ConversationGroup()
  for index in 1...3 { try group.add(savedChat(index, date: now)) }
  #expect(throws: WindowGroupError.self) { try group.add(savedChat(4, date: now)) }
  saved.remove(savedChat(1, date: now).id)
  #expect(group.pins.count == 3)
  #expect(group.pins.first?.id == savedChat(1, date: now).id)
}

@Test func legacySelectionsMigrateOnceAndClearedWidgetPinsStayCleared() throws {
  let legacy = [ConversationPin(savedChat(1, date: Date()))]
  #expect(WidgetConversationPins(saved: nil, legacyPins: legacy).pins == legacy)
  let empty = try JSONEncoder().encode([ConversationPin]())
  #expect(WidgetConversationPins(saved: empty, legacyPins: legacy).pins.isEmpty)
  #expect(WidgetConversationPins(saved: Data("broken".utf8), legacyPins: legacy).pins.isEmpty)
  #expect(WidgetConversationPins(pins: legacy + legacy).pins.count == 1)
}

@Test func allWidgetPinsSurviveTheCutoffAlongsideRecentChatsAndUnpinningExpiresOldOnes() throws {
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
  var saved = WidgetConversationPins()
  for index in 1...10 {
    let item = savedChat(index, date: old)
    saved.add(item)
    let source = home.appendingPathComponent(item.sessionID + ".jsonl")
    let row: [String: Any] = [
      "type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: old),
      "payload": ["type": "agent_message", "message": "Old update"],
    ]
    try JSONSerialization.data(withJSONObject: row).write(to: source)
    sqlite3_exec(
      writer,
      "INSERT INTO threads VALUES('\(item.sessionID)','\(item.title)','','\(source.path)',\(old.timeIntervalSince1970),0)",
      nil, nil, nil)
  }
  let recent = savedChat(11, date: now)
  let source = home.appendingPathComponent(recent.sessionID + ".jsonl")
  try JSONSerialization.data(withJSONObject: [
    "type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
    "payload": ["type": "agent_message", "message": "Recent update"],
  ]).write(to: source)
  sqlite3_exec(
    writer,
    "INSERT INTO threads VALUES('\(recent.sessionID)','Recent','','\(source.path)',\(now.timeIntervalSince1970),0)",
    nil, nil, nil)
  let repository = LocalRepository(paths: paths)
  #expect(repository.conversations(at: now).items.map(\.id) == [recent.id])
  let result = repository.conversations(at: now, pins: saved.pins).items
  #expect(result.map(\.id) == saved.pins.map(\.id) + [recent.id])
  #expect(result.count == 11)
  let restored = WidgetConversationPins(saved: try JSONEncoder().encode(saved.pins))
  #expect(
    repository.conversations(at: now.addingTimeInterval(24 * 3600), pins: restored.pins).items.map(
      \.id) == saved.pins.map(\.id))
  saved.remove(savedChat(1, date: old).id)
  #expect(
    !repository.conversations(at: now, pins: saved.pins).items.contains {
      $0.id == savedChat(1, date: old).id
    })
}

@Test func snapshotKeepsWidgetPinsAndWindowMembershipIndependent() throws {
  var snapshot = Snapshot()
  snapshot.pinnedConversationIDs = [savedChat(1, date: Date()).id]
  snapshot.windowGroupConversationIDs = [savedChat(2, date: Date()).id]
  let data = try JSONEncoder().encode(snapshot)
  let restored = try JSONDecoder().decode(Snapshot.self, from: data)
  #expect(restored.pinnedConversationIDs != restored.windowGroupConversationIDs)
  var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  legacy.removeValue(forKey: "windowGroupConversationIDs")
  let old = try JSONDecoder().decode(
    Snapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
  #expect(old.windowGroupConversationIDs == nil)
  #expect(old.pinnedConversationIDs == snapshot.pinnedConversationIDs)
}
