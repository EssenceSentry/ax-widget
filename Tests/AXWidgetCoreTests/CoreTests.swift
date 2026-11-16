import CSQLite
import Foundation
import Testing
@testable import AXWidgetCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test func remainingIsAllowanceLeftAndNeverInvented() {
    let valid = Allowance(provider: .claude, name: "five_hour", used: 78, observed: now, resets: now.addingTimeInterval(300), status: "fresh")
    #expect(valid.remaining(at: now) == 22)
    #expect(valid.remaining(at: now.addingTimeInterval(301)) == nil)
    for value in [Double.nan, .infinity, -1, 101] {
        var invalid = valid; invalid.used = value
        #expect(invalid.remaining(at: now) == nil)
    }
    var stale = valid; stale.observed = now.addingTimeInterval(-301)
    #expect(stale.remaining(at: now) == nil)
    stale.observed = now.addingTimeInterval(61)
    #expect(stale.remaining(at: now) == nil)
    stale.observed = now; stale.status = "stale"
    #expect(stale.remaining(at: now) == nil)
}

@Test func codexUsesOneLongWindowAndClaudeUsesTwo() {
    var snapshot = Snapshot.demo(at: now)
    snapshot.allowances.append(Allowance(provider: .codex, name: "primary", used: 99, observed: now, resets: now.addingTimeInterval(10), status: "fresh"))
    #expect(snapshot.codex?.name == "secondary")
    #expect(snapshot.codex?.remaining(at: now) == 61)
    #expect(snapshot.claudeFiveHour?.remaining(at: now) == 22)
    #expect(snapshot.claudeWeekly?.remaining(at: now) == 41)
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
    #expect(item.deepLink?.absoluteString == "claude://code/continue?session=local_22222222-2222-4222-8222-222222222222")
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
        "unfinished JSON {"
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
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"Answered"}]}}"#
    ])
    #expect(!answered.needsInput)
}

@Test func boundedTailSurvivesPartialStreamingLine() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("session.jsonl")
    let record = #"{"type":"event_msg","payload":{"type":"agent_message","message":"Latest visible update"}}"#
    try (String(repeating: "x", count: 400) + "\n" + record + "\n{unfinished").write(to: file, atomically: true, encoding: .utf8)
    let result = try TranscriptReader.read(file, maxBytes: 200)
    #expect(result.text == "Latest visible update")
}

@Test func decodeUsageRejectsBooleanPercentages() throws {
    let data = #"{"windows":[{"provider":"codex","name":"secondary","used":true,"observed":1800000000,"resets":1800000300,"status":"fresh"},{"provider":"claude","name":"five_hour","used":78.0,"observed":1800000000,"resets":1800000300,"status":"fresh"}]}"#.data(using: .utf8)!
    let rows = try AxClient.decodeUsage(data)
    #expect(rows[0].used == nil)
    #expect(rows[1].remaining(at: now) == 22)
}

@Test func snapshotRoundtripIsPrivateAndSchemaChecked() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("snapshot.json")
    var value = Snapshot.demo(at: now); value.appearance = .porcelain
    try SnapshotStore.save(value, to: file)
    #expect(SnapshotStore.read(from: file) == value)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    try "{broken".write(to: file, atomically: true, encoding: .utf8)
    #expect(SnapshotStore.read(from: file).conversations.isEmpty)
    #expect(!SnapshotStore.read(from: file).issues.isEmpty)
}

@Test func sqliteReaderCannotMutateProviderDatabase() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: file) }
    var writer: OpaquePointer?
    sqlite3_open(file.path, &writer)
    sqlite3_exec(writer, "CREATE TABLE sample(text TEXT); INSERT INTO sample VALUES('preserved');", nil, nil, nil)
    sqlite3_close(writer)
    let reader = try ReadOnlyDatabase(url: file)
    #expect(try reader.rows("SELECT text FROM sample").first?["text"] == "preserved")
    #expect(throws: (any Error).self) { try reader.rows("DELETE FROM sample") }
    #expect(try reader.rows("SELECT text FROM sample").count == 1)
}
