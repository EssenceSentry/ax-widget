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
  public func contains(_ chat: Conversation) -> Bool {
    pins.contains { pin in
      pin.id == chat.id
        || (pin.provider == .claude && chat.provider == .claude
          && pin.desktopSessionID != nil && pin.desktopSessionID == chat.desktopSessionID)
    }
  }
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
  case ambiguous, cannotFit, changed, claudeRowUnavailable
  public var errorDescription: String? {
    switch self {
    case .claudeRowUnavailable:
      return "Claude's conversation row is unavailable. Open its sidebar and try again."
    case .full: return "Group up to three conversation windows. Remove one before adding another."
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
    guard (1...3).contains(count) else { throw WindowGroupError.cannotFit }
    return try frames(
      minimumWidths: Array(repeating: 320, count: count), visible: visible, gap: gap)
  }
  public static func frames(
    minimumWidths: [CGFloat], visible: CGRect,
    gap: CGFloat = 10, padding: CGFloat = 10
  ) throws -> [CGRect] {
    guard (1...3).contains(minimumWidths.count), visible.width.isFinite, visible.height.isFinite,
      visible.minX.isFinite, visible.minY.isFinite, gap.isFinite, gap >= 0,
      padding.isFinite, padding >= 0,
      minimumWidths.allSatisfy({ $0.isFinite && $0 >= 320 })
    else { throw WindowGroupError.cannotFit }
    let inset = visible.insetBy(dx: padding, dy: padding)
    let minimums = minimumWidths.map(ceil)
    let available = inset.width - CGFloat(minimums.count - 1) * gap
    guard inset.height >= 300, available >= minimums.reduce(0, +) else {
      throw WindowGroupError.cannotFit
    }
    var widths = Array(repeating: CGFloat.zero, count: minimums.count)
    var active = Set(widths.indices)
    var remaining = available
    while !active.isEmpty {
      let share = remaining / CGFloat(active.count)
      let constrained = active.filter { minimums[$0] > share }
      if constrained.isEmpty {
        for index in active { widths[index] = floor(share) }
        break
      }
      for index in constrained {
        widths[index] = minimums[index]
        remaining -= minimums[index]
        active.remove(index)
      }
    }
    widths[widths.count - 1] += available - widths.reduce(0, +)
    var x = inset.minX
    return widths.map { width in
      defer { x += width + gap }
      return CGRect(x: x, y: inset.minY, width: width, height: inset.height)
    }
  }
  /// Fill the usable area of the display containing most of the window. Visible
  /// frames exclude the Dock and menu bar; this never creates a full-screen Space.
  public static func maximizedFrame(for window: CGRect, visibleFrames: [CGRect]) throws -> CGRect {
    func valid(_ rect: CGRect) -> Bool {
      rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
        && rect.width > 0 && rect.height > 0
    }
    guard valid(window) else { throw WindowGroupError.cannotFit }
    let screens = visibleFrames.filter { valid($0) && $0.width >= 320 && $0.height >= 300 }
    func area(_ rect: CGRect) -> CGFloat {
      let overlap = rect.intersection(window)
      return overlap.isNull ? 0 : overlap.width * overlap.height
    }
    func distance(_ rect: CGRect) -> CGFloat {
      let dx = rect.midX - window.midX
      let dy = rect.midY - window.midY
      return dx * dx + dy * dy
    }
    guard
      let screen = screens.max(by: {
        area($0) == area($1) ? distance($0) > distance($1) : area($0) < area($1)
      })
    else { throw WindowGroupError.cannotFit }
    return screen
  }

  public static func accessibilityRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
  }
}
