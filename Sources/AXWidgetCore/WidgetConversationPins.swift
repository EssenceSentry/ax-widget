import Foundation

/// Conversations kept in the widget independently of native window management.
/// Persist navigation metadata only, never message text or question answers.
public struct WidgetConversationPins: Equatable, Sendable {
  public private(set) var pins: [ConversationPin]

  public init(pins: [ConversationPin] = []) {
    var seen: Set<String> = []
    self.pins = pins.filter {
      UUID(uuidString: $0.sessionID) != nil && seen.insert($0.id).inserted
    }
  }

  /// Preserve existing selections once when upgrading from the combined control.
  /// An explicitly saved empty list must never bring legacy selections back.
  public init(saved: Data?, legacyPins: [ConversationPin] = []) {
    let pins =
      saved.map {
        (try? JSONDecoder().decode([ConversationPin].self, from: $0)) ?? []
      } ?? legacyPins
    self.init(pins: pins)
  }

  public mutating func add(_ conversation: Conversation) {
    guard UUID(uuidString: conversation.sessionID) != nil,
      !pins.contains(where: { $0.id == conversation.id })
    else { return }
    pins.append(ConversationPin(conversation))
  }

  public mutating func remove(_ id: String) { pins.removeAll { $0.id == id } }

  public func ordered(_ conversations: [Conversation], limit: Int) -> [Conversation] {
    let ids = Set(pins.map(\.id))
    var seen: Set<String> = []
    let unique = conversations.sorted { $0.updated > $1.updated }.filter {
      seen.insert($0.id).inserted
    }
    let pinned = pins.compactMap { pin in unique.first { $0.id == pin.id } }
    return pinned + unique.filter { !ids.contains($0.id) }.prefix(max(0, limit))
  }
}
