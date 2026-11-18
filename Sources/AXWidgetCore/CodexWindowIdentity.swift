import Foundation

/// Codex's Electron document URL is app://-/index.html for every conversation.
/// Its window title is usable only when native history maps it to exactly one session.
public enum CodexWindowIdentity {
  public static func title(sessionID: String, home: URL = LocalPaths().codexHome) -> String? {
    guard UUID(uuidString: sessionID) != nil else { return nil }
    return try? CodexHistory(home: home)?.uniqueTitle(for: sessionID)
  }
}
