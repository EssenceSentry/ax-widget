import CSQLite
import CoreGraphics
import Foundation
import Testing

@testable import AXWidgetCore

private func chat(_ index: Int, date: Date = Date()) -> Conversation {
  Conversation(
    provider: .codex,
    sessionID: String(format: "11111111-1111-4111-8111-%012d", index),
    title: "Conversation \(index)", updated: date, latestUpdate: "Do not save this prose")
}

@Test func pinGroupCapsAtThreeDeduplicatesAndRetainsPinOrder() throws {
  var group = ConversationGroup()
  try group.add(chat(3))
  try group.add(chat(1))
  try group.add(chat(3))
  try group.add(chat(2))
  #expect(group.pins.map(\.sessionID) == [chat(3), chat(1), chat(2)].map(\.sessionID))
  #expect(throws: WindowGroupError.self) { try group.add(chat(4)) }
  group.remove(chat(1).id)
  try group.add(chat(4))
  #expect(group.pins.map(\.id) == [chat(3), chat(2), chat(4)].map(\.id))
  let data = try JSONEncoder().encode(group.pins)
  #expect(!String(decoding: data, as: UTF8.self).contains("Do not save this prose"))
  let restored = ConversationGroup(
    pins: try JSONDecoder().decode([ConversationPin].self, from: data))
  #expect(restored == group)
  #expect(ConversationGroup(pins: group.pins + group.pins).pins.count == 3)
}

@Test func pinsRejectMissingNativeRegistrationAndInvalidIdentity() {
  var group = ConversationGroup()
  var item = chat(1)
  item.provider = .claude
  #expect(throws: WindowGroupError.self) { try group.add(item) }
  item.desktopSessionID = "local_valid"
  item.sessionID = "new?prompt=do-something"
  #expect(throws: WindowGroupError.self) { try group.add(item) }
  #expect(ConversationGroup(pins: [ConversationPin(item)]).pins.isEmpty)
}

@Test func pinnedOldChatsRemainAlongsideRecentActivityInStableOrder() throws {
  let now = Date()
  let older = chat(1, date: now.addingTimeInterval(-48 * 3600))
  let recent = chat(2, date: now.addingTimeInterval(-10))
  let newest = chat(3, date: now)
  let group = ConversationGroup(pins: [ConversationPin(older), ConversationPin(recent)])
  #expect(
    group.ordered([newest, recent, older], limit: 3).map(\.id) == [older, recent, newest].map(\.id))
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: home) }
  let paths = LocalPaths(home: home)
  try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
  var writer: OpaquePointer?
  sqlite3_open(paths.codexHome.appendingPathComponent("state_5.sqlite").path, &writer)
  defer { sqlite3_close(writer) }
  sqlite3_exec(
    writer,
    "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,updated_at REAL,archived INT)",
    nil, nil, nil)
  for item in [older, recent, newest] {
    let source = home.appendingPathComponent(item.sessionID + ".jsonl")
    let timestamp = ISO8601DateFormatter().string(from: item.updated)
    try
      "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Update\"}}"
      .write(
        to: source, atomically: true, encoding: .utf8)
    sqlite3_exec(
      writer,
      "INSERT INTO threads VALUES('\(item.sessionID)','\(item.title)','','\(source.path)',\(item.updated.timeIntervalSince1970),0)",
      nil, nil, nil)
  }
  let repository = LocalRepository(paths: paths)
  #expect(repository.conversations(at: now).items.map(\.id) == [newest, recent].map(\.id))
  #expect(
    repository.conversations(at: now, pins: group.pins).items.map(\.id)
      == [older, recent, newest].map(\.id))
  sqlite3_exec(writer, "UPDATE threads SET archived=1 WHERE id='\(older.sessionID)'", nil, nil, nil)
  #expect(!repository.conversations(at: now, pins: group.pins).items.contains { $0.id == older.id })
}

@Test func layoutsFitOneTwoOrThreeAndHandleDisplaysLeftOrAbovePrimary() throws {
  let visible = CGRect(x: -1920, y: -900, width: 1920, height: 1080)
  for count in 1...3 {
    let frames = try ConversationWindowLayout.frames(count: count, visible: visible)
    #expect(frames.count == count)
    for (index, frame) in frames.enumerated() {
      #expect(visible.contains(frame))
      #expect(frame.width > 320 && frame.height == 1060)
      if index > 0 { #expect(frames[index - 1].maxX + 10 <= frame.minX) }
    }
  }
  let appKit = CGRect(x: -1920, y: 1080, width: 1920, height: 1050)
  let ax = ConversationWindowLayout.accessibilityRect(appKit, primaryTop: 1080)
  #expect(ax == CGRect(x: -1920, y: -1050, width: 1920, height: 1050))
  for count in [0, 4] {
    #expect(throws: WindowGroupError.self) {
      try ConversationWindowLayout.frames(count: count, visible: visible)
    }
  }
  #expect(throws: WindowGroupError.self) {
    try ConversationWindowLayout.frames(
      count: 3, visible: CGRect(x: 0, y: 0, width: 800, height: 600))
  }
}

@Test func previousSnapshotsDecodeWithoutGroupState() throws {
  let data = try JSONEncoder().encode(Snapshot())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "pinnedConversationIDs")
  let old = try JSONDecoder().decode(
    Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(old.pinnedConversationIDs == nil)
}

@Test func unevenNativeMinimumWidthsFitWithoutOverlapping() throws {
  let display = CGRect(x: 0, y: 33, width: 1512, height: 949)
  let three = try ConversationWindowLayout.frames(
    minimumWidths: [480, 500, 480], visible: display, gap: 6, padding: 6)
  #expect(three.map(\.width) == [494, 500, 494])
  #expect(three.allSatisfy(display.contains))
  #expect(three[0].maxX + 6 == three[1].minX && three[1].maxX + 6 == three[2].minX)
  let two = try ConversationWindowLayout.frames(minimumWidths: [480, 800], visible: display)
  #expect(two.map(\.width) == [682, 800])
  #expect(throws: WindowGroupError.self) {
    try ConversationWindowLayout.frames(
      minimumWidths: [480, 800, 480], visible: display, gap: 6, padding: 6)
  }
}

@Test func codexWindowTitlesRequireUniqueCurrentNativeSessionMapping() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  var writer: OpaquePointer?
  sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &writer)
  defer { sqlite3_close(writer) }
  let first = chat(1).sessionID
  let second = chat(2).sessionID
  sqlite3_exec(
    writer,
    "CREATE TABLE threads(id TEXT,title TEXT); INSERT INTO threads VALUES('\(first)','First'),('\(second)','Second')",
    nil, nil, nil)
  #expect(CodexWindowIdentity.title(sessionID: first, home: home) == "First")
  let index = home.appendingPathComponent("session_index.jsonl")
  try "{\"id\":\"\(first)\",\"thread_name\":\"Renamed\"}\n{unfinished".write(
    to: index, atomically: true, encoding: .utf8)
  #expect(CodexWindowIdentity.title(sessionID: first, home: home) == "Renamed")
  try "{\"id\":\"\(first)\",\"thread_name\":\"Second\"}\n".write(
    to: index, atomically: true, encoding: .utf8)
  #expect(CodexWindowIdentity.title(sessionID: first, home: home) == nil)
  #expect(CodexWindowIdentity.title(sessionID: second, home: home) == nil)
  #expect(CodexWindowIdentity.title(sessionID: chat(3).sessionID, home: home) == nil)
  #expect(CodexWindowIdentity.title(sessionID: "invalid", home: home) == nil)
}

@Test func claudePopoutTitlesRequireUniqueRegisteredDesktopSession() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let paths = LocalPaths(home: home)
  let folder = paths.claudeDesktop.appendingPathComponent("account/org")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  func write(_ id: String, title: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["sessionId": id, "title": title])
    try data.write(to: folder.appendingPathComponent(id + ".json"))
  }
  try write("local_first", title: "First")
  try write("local_second", title: "Second")
  #expect(ClaudeWindowIdentity.title(desktopSessionID: "local_first", paths: paths) == "First")
  try write("local_first", title: "Renamed")
  #expect(ClaudeWindowIdentity.title(desktopSessionID: "local_first", paths: paths) == "Renamed")
  try write("local_second", title: "Renamed")
  #expect(ClaudeWindowIdentity.title(desktopSessionID: "local_first", paths: paths) == nil)
  #expect(ClaudeWindowIdentity.title(desktopSessionID: "local_missing", paths: paths) == nil)
  #expect(ClaudeWindowIdentity.title(desktopSessionID: "../../invalid", paths: paths) == nil)
}

@Test func removedWindowMaximizesOnItsOwnDisplayAndRespectsDesktopInsets() throws {
  let left = CGRect(x: -1920, y: -600, width: 1920, height: 1080)
  let main = CGRect(x: 80, y: 33, width: 1432, height: 949)
  let window = CGRect(x: -700, y: -400, width: 500, height: 800)
  #expect(
    try ConversationWindowLayout.maximizedFrame(for: window, visibleFrames: [main, left]) == left)
  let primary = CGRect(x: 600, y: 39, width: 496, height: 937)
  #expect(
    try ConversationWindowLayout.maximizedFrame(for: primary, visibleFrames: [left, main]) == main)
  let across = CGRect(x: -100, y: 100, width: 800, height: 600)
  #expect(
    try ConversationWindowLayout.maximizedFrame(for: across, visibleFrames: [left, main]) == main)
  let offscreen = CGRect(x: 4000, y: 3000, width: 500, height: 600)
  #expect(
    try ConversationWindowLayout.maximizedFrame(for: offscreen, visibleFrames: [left, main]) == main
  )
}

@Test func maximizingRejectsMissingDisplaysAndInvalidWindowGeometry() {
  let window = CGRect(x: 0, y: 33, width: 500, height: 700)
  #expect(throws: WindowGroupError.self) {
    try ConversationWindowLayout.maximizedFrame(for: window, visibleFrames: [])
  }
  #expect(throws: WindowGroupError.self) {
    try ConversationWindowLayout.maximizedFrame(for: .zero, visibleFrames: [window])
  }
}
