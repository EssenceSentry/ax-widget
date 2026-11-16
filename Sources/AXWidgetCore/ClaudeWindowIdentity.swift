import Foundation

/// Dedicated Claude windows use about:blank, so their native title must map
/// uniquely to a registered Desktop session before a window can be controlled.
public enum ClaudeWindowIdentity {
  public static func title(
    desktopSessionID: String, paths: LocalPaths = LocalPaths()
  ) -> String? {
    guard
      desktopSessionID.range(
        of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
    else { return nil }
    let registered = LocalRepository(paths: paths).desktopRecords().compactMap {
      record -> (id: String, title: String)? in
      guard let id = record["sessionId"] as? String,
        let title = record["title"] as? String, !title.isEmpty
      else { return nil }
      return (id, title)
    }
    let titles = Set(registered.filter { $0.id == desktopSessionID }.map(\.title))
    guard titles.count == 1, let title = titles.first,
      Set(registered.filter { $0.title == title }.map(\.id)) == [desktopSessionID]
    else { return nil }
    return title
  }
}
