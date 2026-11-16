import CoreGraphics
import Foundation

/// Only navigation metadata is saved. Agent messages and question answers are not preferences.
public struct ConversationPin: Codable, Equatable, Identifiable, Sendable {
  public var provider: Provider
  public var sessionID: String
  public var desktopSessionID: String?
  public var title: String
  public var project: String
  public var source: String?
  public var id: String { "\(provider.rawValue):\(sessionID)" }

  public init(_ conversation: Conversation) {
    provider = conversation.provider
    sessionID = conversation.sessionID
    desktopSessionID = conversation.desktopSessionID
    title = conversation.title
    project = conversation.project
    source = conversation.source
  }

  public var conversation: Conversation {
    Conversation(
      provider: provider, sessionID: sessionID, title: title, project: project,
      source: source, updated: .distantPast, desktopSessionID: desktopSessionID)
  }
}

public struct ConversationGroup: Codable, Equatable, Sendable {
  public private(set) var pins: [ConversationPin]
  public init(pins: [ConversationPin] = []) {
    var seen: Set<String> = []
    self.pins = Array(
      pins.filter {
        $0.conversation.deepLink != nil && seen.insert($0.id).inserted
      }.prefix(3))
  }
  public mutating func add(_ conversation: Conversation) throws {
    guard !pins.contains(where: { $0.id == conversation.id }) else { return }
    guard pins.count < 3 else { throw WindowGroupError.full }
    guard conversation.deepLink != nil else { throw WindowGroupError.unregistered }
    pins.append(ConversationPin(conversation))
  }
  public mutating func remove(_ id: String) { pins.removeAll { $0.id == id } }
  public func ordered(_ conversations: [Conversation], limit: Int) -> [Conversation] {
    let ids = Set(pins.map(\.id))
    let pinned = pins.compactMap { pin in conversations.first { $0.id == pin.id } }
    return pinned
      + conversations.filter { !ids.contains($0.id) }
      .sorted { $0.updated > $1.updated }.prefix(max(0, limit - pinned.count))
  }
}

public enum WindowGroupError: LocalizedError {
  case full, unregistered, accessibility
  case unavailable(String)
  case ambiguous, cannotFit, changed
  public var errorDescription: String? {
    switch self {
    case .full: return "Pin up to three conversations. Unpin one before adding another."
    case .unregistered: return "This conversation has no Desktop registration yet."
    case .accessibility:
      return
        "Enable AX Widget in System Settings → Privacy & Security → Accessibility to manage conversation windows."
    case .unavailable(let detail): return detail
    case .ambiguous:
      return
        "The conversation window could not be identified uniquely. Open it in its own window and try again."
    case .cannotFit:
      return
        "These windows do not fit side by side on this display. Use a larger display or pin fewer conversations."
    case .changed:
      return
        "A pinned window changed conversations. Show the group again to reopen the original conversation."
    }
  }
}

public enum ConversationWindowLayout {
  /// Coordinates are in the Accessibility global, top-left coordinate system.
  public static func frames(count: Int, visible: CGRect, gap: CGFloat = 10) throws -> [CGRect] {
    guard (1...3).contains(count), visible.width.isFinite, visible.height.isFinite,
      visible.minX.isFinite, visible.minY.isFinite, gap.isFinite, gap >= 0,
      visible.width > 0, visible.height > 0
    else { throw WindowGroupError.cannotFit }
    let inset = visible.insetBy(dx: 10, dy: 10)
    let width = floor((inset.width - CGFloat(count - 1) * gap) / CGFloat(count))
    guard width >= 320, inset.height >= 300 else { throw WindowGroupError.cannotFit }
    return (0..<count).map { index in
      CGRect(
        x: inset.minX + CGFloat(index) * (width + gap), y: inset.minY,
        width: width, height: inset.height)
    }
  }
  public static func accessibilityRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
  }
}
