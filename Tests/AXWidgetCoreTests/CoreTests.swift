import CSQLite
import Foundation
import Testing

@testable import AXWidgetCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func transientPanelHidesBothWindowsWhenClosed() {
  var presentation = FloatingPresentation()
  #expect(!presentation.usageVisible && !presentation.conversationsVisible)
  presentation.open()
  #expect(presentation.usageVisible && presentation.conversationsVisible)
  presentation.close()
  #expect(!presentation.usageVisible && !presentation.conversationsVisible)
}

@Test func keepingFloatingRetainsOnlyThePillWhenClosed() {
  var presentation = FloatingPresentation(keepFloating: true)
  #expect(presentation.usageVisible && !presentation.conversationsVisible)
  presentation.toggle()
  #expect(presentation.usageVisible && presentation.conversationsVisible)
  presentation.toggle()
  #expect(presentation.usageVisible && !presentation.conversationsVisible)
}

@Test func disablingFloatingDoesNotDismissAnOpenPanel() {
  var presentation = FloatingPresentation(keepFloating: true)
  presentation.open()
  presentation.keepFloating = false
  #expect(presentation.usageVisible && presentation.conversationsVisible)
  presentation.close()
  #expect(!presentation.usageVisible && !presentation.conversationsVisible)
}

@Test func markdownKeepsLineBreaksAndInlineFormatting() {
  let rendered = UpdateMarkdown.render(
    "**Ready** and *waiting* for `tests`.\n\n[Open](https://example.com)")
  #expect(String(rendered.characters) == "Ready and waiting for tests.\n\nOpen")
  #expect(
    rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
  #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
  #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
  #expect(rendered.runs.contains { $0.link == URL(string: "https://example.com") })
}

@Test func unavailableSecondaryDoesNotHideFreshCodexAllowance() {
  let date = Date()
  let primary = Allowance(
    provider: .codex, name: "primary", used: 45, observed: date,
    resets: date.addingTimeInterval(3600), status: "fresh")
  let unavailable = Allowance(
    provider: .codex, name: "secondary", used: nil, observed: date,
    resets: nil, status: "unavailable")
  let snapshot = Snapshot(allowances: [primary, unavailable])
  #expect(snapshot.codex?.name == "primary")
  #expect(snapshot.codex?.remaining() == 55)
}

@Test func markdownTablesListsAndInternalMetadataAreStructured() {
  let document = MarkdownDocument(
    """
    ## Plan

    | Remaining work | Estimated effort |
    |---|---:|
    | Consolidate the **repairs** | 1–2 days |
    | Complete `tests` | 2–4 days |

    - First item
    - Second item

    ```swift
    let ready = true
    ```

    <oai-mem-citation>
    <citation_entries>internal provenance</citation_entries>
    </oai-mem-citation>
    """)
  #expect(!document.source.contains("internal provenance"))
  #expect(document.blocks.first?.kind == .heading(2))
  let table = document.blocks.first { $0.kind == .table }
  #expect(table?.rows.count == 3)
  #expect(table?.columns.count == 2)
  #expect(table?.rows[1][0].characters.contains("*") == false)
  #expect(String(table!.rows[2][1].characters) == "2–4 days")
  #expect(
    document.blocks.filter {
      if case .listItem = $0.kind { return true }
      return false
    }.count == 2)
  #expect(document.blocks.last?.kind == .code)
  #expect(MarkdownDocument.visibleSource("Visible\n<oai-mem-citation>truncated") == "Visible")
}

@Test func remainingIsAllowanceLeftAndNeverInvented() {
  let valid = Allowance(
    provider: .claude, name: "five_hour", used: 78, observed: now,
    resets: now.addingTimeInterval(300), status: "fresh")
  #expect(valid.remaining(at: now) == 22)
  #expect(valid.remaining(at: now.addingTimeInterval(301)) == nil)
  for value in [Double.nan, .infinity, -1, 101] {
    var invalid = valid
    invalid.used = value
    #expect(invalid.remaining(at: now) == nil)
  }
  var stale = valid
  stale.observed = now.addingTimeInterval(-301)
  #expect(stale.remaining(at: now) == nil)
  stale.observed = now.addingTimeInterval(61)
  #expect(stale.remaining(at: now) == nil)
  stale.observed = now
  stale.status = "stale"
  #expect(stale.remaining(at: now) == nil)
}

@Test func codexUsesOneLongWindowAndClaudeUsesTwo() {
  var snapshot = Snapshot.demo(at: now)
  snapshot.allowances.append(
    Allowance(
      provider: .codex, name: "primary", used: 99, observed: now,
      resets: now.addingTimeInterval(10), status: "fresh"))
  #expect(snapshot.codex(at: now)?.name == "secondary")
  #expect(snapshot.codex(at: now)?.remaining(at: now) == 61)
  #expect(snapshot.claudeFiveHour?.remaining(at: now) == 22)
  #expect(snapshot.claudeWeekly?.remaining(at: now) == 41)
}

@Test func idleCodexDisplayKeepsItsObservationWithoutClaimingItIsFresh() {
  var value = Allowance(
    provider: .codex, name: "primary", used: 48,
    observed: now, resets: now.addingTimeInterval(7200), status: "fresh")
  #expect(value.remaining(at: now.addingTimeInterval(300)) == 52)
  #expect(!value.isCached(at: now.addingTimeInterval(300)))
  let idle = now.addingTimeInterval(301)
  #expect(value.remaining(at: idle) == nil)
  #expect(value.displayRemaining(at: idle) == 52)
  #expect(value.isCached(at: idle))
  #expect(value.displayRemaining(at: now.addingTimeInterval(7199)) == 52)
  #expect(value.displayRemaining(at: now.addingTimeInterval(7200)) == nil)
  value.status = "stale"
  #expect(value.displayRemaining(at: idle) == 52)
  for status in ["unavailable", "unknown", "error"] {
    value.status = status
    #expect(value.displayRemaining(at: idle) == nil)
  }
  value.status = "fresh"
  value.provider = .claude
  #expect(value.displayRemaining(at: idle) == nil)
  value.provider = .codex
  for invalid in [Double.nan, .infinity, -1, 101] {
    value.used = invalid
    #expect(value.displayRemaining(at: idle) == nil)
  }
  value.used = 48
  value.observed = now.addingTimeInterval(61)
  #expect(value.displayRemaining(at: now) == nil)
  value.observed = nil
  #expect(value.displayRemaining(at: idle) == nil)
  value.observed = now
  value.resets = nil
  #expect(value.displayRemaining(at: idle) == nil)
}

@Test func codexSelectsFreshUsageThenAValidCachedWindow() {
  var snapshot = Snapshot(allowances: [
    Allowance(
      provider: .codex, name: "secondary", used: 39,
      observed: now.addingTimeInterval(-600), resets: now.addingTimeInterval(-1), status: "stale"),
    Allowance(
      provider: .codex, name: "primary", used: 48,
      observed: now.addingTimeInterval(-600), resets: now.addingTimeInterval(7200), status: "stale"),
  ])
  #expect(snapshot.codex(at: now)?.name == "primary")
  #expect(snapshot.codex(at: now)?.displayRemaining(at: now) == 52)
  snapshot.allowances[0].resets = now.addingTimeInterval(86400)
  snapshot.allowances[1].observed = now
  snapshot.allowances[1].status = "fresh"
  #expect(snapshot.codex(at: now)?.name == "primary")
  snapshot.allowances[1].used = nil
  snapshot.allowances[1].status = "unavailable"
  #expect(snapshot.codex(at: now)?.name == "secondary")
  #expect(snapshot.codex(at: now)?.isCached(at: now) == true)
}

@Test func activeJobCountDoesNotHideAnotherJobsNumericProgress() {
  let numeric = TaskProgress(done: 1, total: 3, unit: "checks", stage: "Checking", runningCount: 1)
  let indeterminate = TaskProgress(runningCount: 1)
  for (newer, older) in [(numeric, indeterminate), (indeterminate, numeric)] {
    var summary = newer
    summary.include(older)
    #expect(summary.runningCount == 2)
    #expect(summary.done == 1 && summary.total == 3 && summary.unit == "checks")
    #expect(summary.stage == "Checking")
  }
  var summary = numeric
  summary.include(TaskProgress(done: 8, total: 9, stage: "Older progress", runningCount: 1))
  #expect(summary.runningCount == 2)
  #expect(summary.done == 1 && summary.total == 3)
}

@Test func indeterminateProgressIsNotZeroOrComplete() {
  #expect(TaskProgress().fraction == nil)
  #expect(TaskProgress(done: 6, total: 9).fraction == 2.0 / 3.0)
  #expect(TaskProgress(done: -1, total: 10).fraction == nil)
  #expect(TaskProgress(done: 0, total: 0).fraction == nil)
  #expect(TaskProgress(done: .infinity, total: 10).fraction == nil)
  #expect(TaskProgress(done: 12, total: 10, runningCount: 1).fraction == 1)
  #expect(TaskProgress(done: 12, total: 10, runningCount: 1).runningCount == 1)
}

@Test func routingPreservesExactIdentityAndDoesNotCreateConversations() {
  let id = "11111111-1111-4111-8111-111111111111"
  var item = Conversation(provider: .codex, sessionID: id, title: "Title", updated: now)
  #expect(item.deepLink?.absoluteString == "codex://threads/\(id)")
  #expect(item.widgetLink?.absoluteString == "ax-widget://conversation/codex/\(id)")
  item.provider = .claude
  #expect(item.deepLink == nil)
  item.desktopSessionID = "local_22222222-2222-4222-8222-222222222222"
  #expect(
    item.deepLink?.absoluteString
      == "claude://code/continue?session=local_22222222-2222-4222-8222-222222222222")
  item.desktopSessionID = "last"
  #expect(item.deepLink == nil)
  item.sessionID = "new?prompt=do-something"
  #expect(item.deepLink == nil)
  #expect(item.widgetLink == nil)
}

@Test func transcriptExtractsOnlyHumanVisibleAgentProse() {
  let rows = [
    #"{"type":"response_item","timestamp":"2026-11-16T15:00:00Z","payload":{"type":"message","role":"assistant","phase":"analysis","content":[{"type":"output_text","text":"private reasoning"}]}}"#,
    #"{"type":"response_item","timestamp":"2026-11-16T15:01:00.123Z","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Preparing one complete environment."}]}}"#,
    #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"secret command"}}"#,
    #"{"type":"event_msg","payload":{"type":"token_count","text":"not commentary"}}"#,
    #"{"type":"response_item","payload":{"type":"function_call_output","output":"not an update"}}"#,
    "unfinished JSON {",
  ]
  let update = TranscriptReader.parse(rows)
  #expect(update.text == "Preparing one complete environment.")
  #expect(update.date != nil)
  #expect(!update.needsInput)
}

@Test func claudeUpdateIgnoresThinkingAndToolBodies() {
  let update = TranscriptReader.parse([
    #"{"type":"assistant","timestamp":"2026-11-16T15:00:00Z","message":{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"The review is ready."},{"type":"tool_use","id":"a","name":"AskUserQuestion","input":{"question":"Cutoff?"}}]}}"#
  ])
  #expect(update.text == "The review is ready.")
  #expect(update.needsInput)
  let answered = TranscriptReader.parse([
    #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"AskUserQuestion"}]}}"#,
    #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"Answered"}]}}"#,
  ])
  #expect(!answered.needsInput)
}

@Test func boundedTailSurvivesPartialStreamingLine() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let file = folder.appendingPathComponent("session.jsonl")
  let record =
    #"{"type":"event_msg","payload":{"type":"agent_message","message":"Latest visible update"}}"#
  try (String(repeating: "x", count: 400) + "\n" + record + "\n{unfinished").write(
    to: file, atomically: true, encoding: .utf8)
  let result = try TranscriptReader.read(file, maxBytes: 200)
  #expect(result.text == "Latest visible update")
}

@Test func decodeUsageRejectsBooleanPercentages() throws {
  let data =
    #"{"windows":[{"provider":"codex","name":"secondary","used":true,"observed":1800000000,"resets":1800000300,"status":"fresh"},{"provider":"claude","name":"five_hour","used":78.0,"observed":1800000000,"resets":1800000300,"status":"fresh"}]}"#
    .data(using: .utf8)!
  let rows = try AxClient.decodeUsage(data)
  #expect(rows[0].used == nil)
  #expect(rows[1].remaining(at: now) == 22)
}

@Test func snapshotRoundtripIsPrivateAndSchemaChecked() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let file = folder.appendingPathComponent("snapshot.json")
  var value = Snapshot.demo(at: now)
  value.appearance = .porcelain
  try SnapshotStore.save(value, to: file)
  #expect(SnapshotStore.read(from: file) == value)
  let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
  #expect((attributes[.posixPermissions] as? Int) == 0o600)
  try "{broken".write(to: file, atomically: true, encoding: .utf8)
  #expect(SnapshotStore.read(from: file).conversations.isEmpty)
  #expect(!SnapshotStore.read(from: file).issues.isEmpty)
}

@Test func sqliteReaderCannotMutateProviderDatabase() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".sqlite")
  defer { try? FileManager.default.removeItem(at: file) }
  var writer: OpaquePointer?
  sqlite3_open(file.path, &writer)
  sqlite3_exec(
    writer, "CREATE TABLE sample(text TEXT); INSERT INTO sample VALUES('preserved');", nil, nil, nil
  )
  sqlite3_close(writer)
  let reader = try ReadOnlyDatabase(url: file)
  #expect(try reader.rows("SELECT text FROM sample").first?["text"] == "preserved")
  #expect(throws: (any Error).self) { try reader.rows("DELETE FROM sample") }
  #expect(try reader.rows("SELECT text FROM sample").count == 1)
}

@Test func internalProviderSessionsStayOutOfConversationCards() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("session.jsonl")
  for line in [
    #"{"type":"session_meta","payload":{"thread_source":"guardian_review","source":"cli"}}"#,
    #"{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{}}}}}"#,
    #"{"type":"user","entrypoint":"sdk-cli","isSidechain":false}"#,
  ] {
    try line.write(to: file, atomically: true, encoding: .utf8)
    #expect(!TranscriptReader.isMainConversation(file))
  }
  try #"{"type":"user","entrypoint":"sdk-cli","isSidechain":false,"sessionKind":"interactive"}"#
    .write(to: file, atomically: true, encoding: .utf8)
  #expect(TranscriptReader.isMainConversation(file, registeredDesktop: true))
  #expect(!TranscriptReader.isMainConversation(file))
  try #"{"type":"user","entrypoint":"claude-vscode","isSidechain":false}"#.write(
    to: file, atomically: true, encoding: .utf8)
  #expect(TranscriptReader.isMainConversation(file))
}

@Test func desktopRegistrationAndLatestProseAreJoinedWithoutChangingHistory() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let paths = LocalPaths(home: home)
  defer { try? FileManager.default.removeItem(at: home) }
  let records = paths.claudeDesktop.appendingPathComponent("account/org")
  try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
  let id = "11111111-1111-4111-8111-111111111111"
  let nativeID = "local_22222222-2222-4222-8222-222222222222"
  let cwd = "/fixture/project"
  let source = paths.claudeHome.appendingPathComponent("projects/-fixture-project/\(id).jsonl")
  try FileManager.default.createDirectory(
    at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
  let content =
    #"{"type":"user","entrypoint":"cli","message":{"content":"Review"}}"# + "\n"
    + "{\"type\":\"assistant\",\"timestamp\":\"\(ISO8601DateFormatter().string(from: now))\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Reviewed the environment repair.\"}]}}"
  try content.write(to: source, atomically: true, encoding: .utf8)
  let record: [String: Any] = [
    "sessionId": nativeID, "cliSessionId": id, "cwd": cwd, "title": "Integration review",
    "lastActivityAt": 1_800_000_000,
  ]
  try JSONSerialization.data(withJSONObject: record).write(
    to: records.appendingPathComponent(nativeID + ".json"))
  // A burst of newer SDK workers cannot displace the interactive Desktop chat.
  try FileManager.default.createDirectory(at: paths.axData, withIntermediateDirectories: true)
  var writer: OpaquePointer?
  sqlite3_open(paths.axData.appendingPathComponent("catalog.sqlite3").path, &writer)
  sqlite3_exec(
    writer,
    "CREATE TABLE conversations(provider TEXT,id TEXT,title TEXT,project TEXT,source TEXT,updated REAL,mtime REAL)",
    nil, nil, nil)
  for index in 0..<30 {
    let worker = home.appendingPathComponent("worker-\(index).jsonl")
    try #"{"type":"user","entrypoint":"sdk-cli","isSidechain":false}"#.write(
      to: worker, atomically: true, encoding: .utf8)
    let sql =
      "INSERT INTO conversations VALUES('claude','\(UUID().uuidString)','Worker','','\(worker.path)',1800000001,1800000001)"
    sqlite3_exec(writer, sql, nil, nil, nil)
  }
  sqlite3_close(writer)
  let result = LocalRepository(paths: paths).conversations(at: now)
  #expect(result.items.count == 1)
  #expect(result.items.first?.title == "Integration review")
  #expect(result.items.first?.desktopSessionID == nativeID)
  #expect(result.items.first?.latestUpdate == "Reviewed the environment repair.")
  #expect(try String(contentsOf: source, encoding: .utf8) == content)
  #expect(
    LocalRepository(paths: paths).conversations(at: now.addingTimeInterval(12 * 3600 + 1)).items
      .isEmpty)
}
