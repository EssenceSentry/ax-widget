import AXWidgetCore

/// Only delivery receipts are persisted. A provider can acknowledge a reply
/// before its transcript records the answer.
struct SentQuestions: Codable, Equatable {
  private var calls: [String: Set<String>] = [:]

  private func key(_ chat: Conversation) -> String {
    if chat.provider == .claude, let desktop = chat.desktopSessionID { return "claude:\(desktop)" }
    return chat.id
  }

  func contains(_ call: String, in chat: Conversation) -> Bool {
    calls[key(chat)]?.contains(call) == true
  }

  mutating func record(_ call: String, in chat: Conversation) {
    calls[key(chat), default: []].insert(call)
  }

  func apply(to chats: inout [Conversation]) {
    for index in chats.indices {
      guard let sent = calls[key(chats[index])], let groups = chats[index].questions else {
        continue
      }
      chats[index].questions = groups.filter { !sent.contains($0.id) }
      chats[index].needsAttention = chats[index].questions?.isEmpty == false
    }
  }

  mutating func reconcile(with chats: [Conversation]) {
    for chat in chats {
      let id = key(chat)
      guard let sent = calls[id], let groups = chat.questions else { continue }
      let outstanding = sent.intersection(groups.map(\.id))
      calls[id] = outstanding.isEmpty ? nil : outstanding
    }
  }
}
