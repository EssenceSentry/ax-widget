import Foundation
import Testing

@testable import AXWidgetCore

private func line(_ value: [String: Any]) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

private func codexAsk(_ call: String = "call-widget", multiple: Bool = false) throws -> String {
  let arguments: [String: Any] = [
    "questions": [
      [
        "id": "next", "title": "Which next step?", "multiSelect": multiple,
        "options": ["Continue", "Wait"],
      ] as [String: Any]
    ]
  ]
  return try line([
    "type": "response_item",
    "payload": [
      "type": "function_call",
      "name": "functions.request_user_input_async", "call_id": call,
      "arguments": line(arguments),
    ],
  ])
}

@Test func acceptedAsyncQuestionStaysPendingUntilItsMatchingReply() throws {
  let ask = try codexAsk()
  let accepted = try line([
    "type": "response_item",
    "payload": [
      "type": "function_call_output",
      "call_id": "call-widget", "output": "{\"accepted\":true}",
    ],
  ])
  let unrelated = try line([
    "type": "response_item",
    "payload": [
      "type": "message", "role": "user",
      "content": [["type": "input_text", "text": "An unrelated update."]],
    ],
  ])
  let pending = TranscriptReader.parse([ask, accepted, unrelated])
  #expect(pending.needsInput)
  #expect(pending.questions.count == 1)
  let group = try #require(pending.questions.first)
  #expect(group.kind == .codexAsync)
  #expect(group.questions.first?.options.map(\.label) == ["Continue", "Wait"])
  let reply = try group.codexReply(["next": ["Continue"]])
  let message = try line([
    "type": "response_item",
    "payload": [
      "type": "message", "role": "user",
      "content": [["type": "input_text", "text": "Reply context\n" + reply]],
    ],
  ])
  let answered = TranscriptReader.parse([ask, accepted, message])
  #expect(!answered.needsInput)
  #expect(answered.questions.isEmpty)
}

@Test func questionReplyCannotClearADifferentCall() throws {
  let first = try codexAsk("first")
  let second = try codexAsk("second")
  let groups = TranscriptReader.parse([first, second]).questions
  let reply = try #require(groups.first).codexReply(["next": ["Wait"]])
  let message = try line([
    "type": "response_item",
    "payload": [
      "type": "message", "role": "user",
      "content": [["type": "input_text", "text": reply]],
    ],
  ])
  let pending = TranscriptReader.parse([first, second, message])
  #expect(pending.questions.map(\.id) == ["second"])
}

@Test func desktopSendRequiresTheExactRecordedUserReply() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
  defer { try? FileManager.default.removeItem(at: file) }
  let request = try codexAsk()
  let group = try #require(TranscriptReader.parse([request]).questions.first)
  let body = try group.codexReply(["next": ["Continue"]])
  func message(_ role: String) throws -> String {
    try line(["type": "response_item", "payload": ["type": "message", "role": role,
      "content": [["type": "input_text", "text": body]]]])
  }
  try (request + "\n" + message("assistant") + "\n").write(to: file, atomically: true, encoding: .utf8)
  #expect(try !TranscriptReader.confirmedReply(file, call: group.id, index: 0, answer: "Continue"))
  let handle = try FileHandle(forWritingTo: file)
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((message("user") + "\n").utf8))
  #expect(try TranscriptReader.confirmedReply(file, call: group.id, index: 0, answer: "Continue"))
  #expect(try !TranscriptReader.confirmedReply(file, call: group.id, index: 1, answer: "Continue"))
  #expect(try !TranscriptReader.confirmedReply(file, call: group.id, index: 0, answer: "Wait"))
  #expect(try TranscriptReader.pendingQuestions(file).isEmpty)
}

@Test func oldQuestionsDoNotSurviveANewOrAbortedCodexTurn() throws {
  let old = try codexAsk("old-turn")
  let newTurn = try line(["type": "event_msg", "payload": ["type": "task_started"]])
  let complete = try line(["type": "event_msg", "payload": ["type": "task_complete"]])
  let aborted = try line(["type": "event_msg", "payload": ["type": "turn_aborted"]])
  #expect(TranscriptReader.parse([old, newTurn, complete]).questions.isEmpty)
  let current = try codexAsk("current-turn")
  #expect(
    TranscriptReader.parse([old, newTurn, current, complete]).questions.map(\.id) == [
      "current-turn"
    ])
  #expect(TranscriptReader.parse([newTurn, current, aborted]).questions.isEmpty)
}

@Test func coldQuestionReaderStartsAtLatestTurnAcrossLargeRecords() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("cold-boundary.jsonl")
  let meta = try line(["type": "session_meta", "payload": ["id": "fixture"]])
  let boundary = try line(["type": "event_msg", "payload": ["type": "task_started"]])
  let noise = try line([
    "type": "response_item",
    "payload": [
      "type": "function_call_output", "call_id": "not-a-question",
      "output": String(repeating: "ordinary output ", count: 100_000),
    ],
  ])
  try
    ([meta, boundary, codexAsk("historical"), noise, boundary, codexAsk("current"), noise]
    .joined(separator: "\n") + "\n").write(to: source, atomically: true, encoding: .utf8)
  #expect(try TranscriptReader.read(source, maxBytes: 1024).questions.map(\.id) == ["current"])
}

@Test func questionRepliesPreserveNativeIdentityAndRejectEmptyAnswers() throws {
  let group = try #require(TranscriptReader.parse([codexAsk(multiple: true)]).questions.first)
  #expect(group.questions.first?.multiple == true)
  #expect(throws: (any Error).self) { try group.codexReply([:]) }
  let reply = try group.codexReply(["next": ["Continue", "Wait"]])
  let body = reply.replacingOccurrences(of: "<send_user_message_question_reply>", with: "")
    .replacingOccurrences(of: "</send_user_message_question_reply>", with: "")
  let data = try #require(body.data(using: .utf8))
  let items = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  let key = try #require((items.first?["questionItemId"] as? String)?.data(using: .utf8))
  let identity = try #require(JSONSerialization.jsonObject(with: key) as? [Any])
  #expect(identity[0] as? String == "request_user_input_async")
  #expect(identity[1] as? String == "call-widget")
  #expect(identity[2] as? Int == 0)
  #expect(items.first?["answer"] as? String == "Continue, Wait")
}

@Test func claudeStructuredQuestionKeepsOptionsAndClearsOnToolResult() throws {
  let ask = try line([
    "type": "assistant",
    "message": [
      "content": [
        [
          "type": "tool_use", "id": "claude-call",
          "name": "AskUserQuestion",
          "input": [
            "questions": [
              [
                "header": "Next", "question": "Which next step?",
                "multiSelect": true, "isOther": false,
                "options": [
                  ["label": "Review", "description": "Inspect the evidence."],
                  ["label": "Wait", "description": "Keep it paused."],
                ],
              ]
            ]
          ],
        ]
      ]
    ],
  ])
  let pending = TranscriptReader.parse([ask])
  #expect(pending.needsInput)
  let question = try #require(pending.questions.first?.questions.first)
  #expect(question.multiple)
  #expect(!question.allowsText)
  #expect(question.options.first?.description == "Inspect the evidence.")
  let answer = try line([
    "type": "user",
    "message": [
      "content": [
        [
          "type": "tool_result",
          "tool_use_id": "claude-call", "content": "Answered in the native question form.",
        ]
      ]
    ],
  ])
  #expect(!TranscriptReader.parse([ask, answer]).needsInput)
}

@Test func newConversationLinksOpenNativeComposersWithoutPrompts() throws {
  let folder = "/tmp/Widget Test & More"
  let codex = try #require(Provider.codex.newConversationURL(project: folder))
  let claude = try #require(Provider.claude.newConversationURL(project: folder))
  let codexParts = try #require(URLComponents(url: codex, resolvingAgainstBaseURL: false))
  let claudeParts = try #require(URLComponents(url: claude, resolvingAgainstBaseURL: false))
  #expect(codexParts.scheme == "codex" && codexParts.host == "new")
  #expect(codexParts.queryItems == [URLQueryItem(name: "path", value: folder)])
  #expect(claudeParts.scheme == "claude" && claudeParts.path == "/new")
  #expect(claudeParts.queryItems == [URLQueryItem(name: "folder", value: folder)])
  #expect(Provider.codex.newConversationURL(project: "relative/path") == nil)
}

@Test func claudeNativeAnswerClearsTheIncrementalAndColdQuestionReaders() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("claude-native-answer.jsonl")
  let ask = try line([
    "type": "assistant",
    "message": [
      "content": [
        [
          "type": "tool_use", "id": "native-question", "name": "AskUserQuestion",
          "input": [
            "questions": [
              [
                "question": "Continue?",
                "options": [
                  ["label": "Continue", "description": "Proceed."],
                  ["label": "Wait", "description": "Stay paused."],
                ],
              ]
            ]
          ],
        ]
      ]
    ],
  ])
  try (ask + "\n").write(to: source, atomically: true, encoding: .utf8)
  #expect(try TranscriptReader.read(source).questions.map(\.id) == ["native-question"])
  let reply = try line([
    "type": "user",
    "message": [
      "role": "user",
      "content": [
        [
          "type": "tool_result", "tool_use_id": "native-question",
          "content": "User has answered your questions. Continue with that answer.",
        ]
      ],
    ], "toolUseResult": ["answers": ["Continue?": "Continue"]],
  ])
  let writer = try FileHandle(forWritingTo: source)
  try writer.seekToEnd()
  try writer.write(contentsOf: Data((reply + "\n").utf8))
  try writer.close()
  #expect(try !TranscriptReader.read(source).needsInput)
  let cold = directory.appendingPathComponent("claude-cold-answer.jsonl")
  try FileManager.default.copyItem(at: source, to: cold)
  #expect(try TranscriptReader.read(cold).questions.isEmpty)
}

@Test func pendingQuestionSurvivesLargeToolOutputAndSplitReplyRecords() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("conversation.jsonl")
  let ask = try codexAsk()
  try (ask + "\n").write(to: source, atomically: true, encoding: .utf8)
  let group = try #require(TranscriptReader.read(source, maxBytes: 1024).questions.first)
  let noise = try line([
    "type": "response_item",
    "payload": [
      "type": "custom_tool_call_output",
      "call_id": "large-output", "output": String(repeating: "tool output ", count: 100_000),
    ],
  ])
  let writer = try FileHandle(forWritingTo: source)
  defer { try? writer.close() }
  try writer.seekToEnd()
  try writer.write(contentsOf: Data((noise + "\n").utf8))
  #expect(try TranscriptReader.read(source, maxBytes: 1024).needsInput)
  let cold = directory.appendingPathComponent("cold.jsonl")
  try FileManager.default.copyItem(at: source, to: cold)
  #expect(try TranscriptReader.read(cold, maxBytes: 1024).needsInput)
  let reply = try group.codexReply(["next": ["Continue"]])
  let row =
    try line([
      "type": "response_item",
      "payload": [
        "type": "message", "role": "user",
        "content": [["type": "input_text", "text": reply]],
      ],
    ]) + "\n"
  let bytes = Data(row.utf8)
  let midpoint = bytes.count / 2
  try writer.write(contentsOf: bytes.prefix(midpoint))
  #expect(try TranscriptReader.read(source, maxBytes: 1024).needsInput)
  try writer.write(contentsOf: bytes.suffix(from: midpoint))
  #expect(try !TranscriptReader.read(source, maxBytes: 1024).needsInput)
}
