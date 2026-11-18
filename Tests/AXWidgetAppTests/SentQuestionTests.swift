import AXWidgetCore
import Foundation
import Testing

@testable import AXWidgetApp

@Test func sentBatchDisappearsDuringTranscriptLagAndAfterRelaunch() throws {
  let withQuestions = Snapshot.demo().conversations.first(where: \.needsAttention)
  var chat = try #require(withQuestions)
  var first = try #require(chat.questions?.first)
  first.id = "first"
  var next = first
  next.id = "next"
  chat.questions = [first, next]
  var other = chat
  other.sessionID = UUID().uuidString
  other.desktopSessionID = "local_other"
  var receipts = SentQuestions()
  receipts.record(first.id, in: chat)
  let data = try JSONEncoder().encode(receipts)
  #expect(!String(decoding: data, as: UTF8.self).contains(first.questions[0].title))
  var loaded = try JSONDecoder().decode(SentQuestions.self, from: data)
  var stale = [chat, other]
  loaded.reconcile(with: stale)
  loaded.apply(to: &stale)
  #expect(stale[0].questions == [next])
  #expect(stale[0].needsAttention)
  #expect(stale[1].questions == [first, next])
  loaded.record(next.id, in: chat)
  loaded.apply(to: &stale)
  #expect(stale[0].questions == [])
  #expect(!stale[0].needsAttention)
  #expect(stale[1].needsAttention)
  var unread = chat
  unread.questions = nil
  loaded.reconcile(with: [unread])
  #expect(loaded.contains(first.id, in: chat))
  loaded.reconcile(with: [stale[0]])
  #expect(!loaded.contains(first.id, in: chat))
}

@Test func receiptsAndGroupArrowsFollowClaudeDesktopIdentity() {
  var chat = Conversation(
    provider: .claude, sessionID: UUID().uuidString,
    title: "Fixture", updated: Date(), desktopSessionID: "local_first")
  let group = ConversationGroup(pins: [ConversationPin(chat)])
  var receipts = SentQuestions()
  receipts.record("request", in: chat)
  chat.sessionID = UUID().uuidString
  #expect(group.contains(chat))
  #expect(receipts.contains("request", in: chat))
  chat.desktopSessionID = "local_different"
  #expect(!group.contains(chat))
  #expect(!receipts.contains("request", in: chat))
  chat.provider = .codex
  chat.desktopSessionID = "local_first"
  #expect(!group.contains(chat))
  #expect(!receipts.contains("request", in: chat))
}
