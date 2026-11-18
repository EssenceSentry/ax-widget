import AXWidgetCore
import AppKit
import ApplicationServices

extension WindowAX {
  static func isStandardWindow(_ window: AXUIElement) -> Bool {
    value(window, kAXRoleAttribute) as? String == kAXWindowRole
      && value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
  }

  static func isRegularView(_ window: AXUIElement, of pin: ConversationPin) -> Bool {
    guard isStandardWindow(window) else { return false }
    if pin.provider == .codex { return matches(window, pin: pin) }
    return pin.desktopSessionID.map { isClaudeMain(window, session: $0) } ?? false
  }

  @MainActor static func focus(_ window: AXUIElement, pid: pid_t) async throws {
    let app = AXUIElementCreateApplication(pid)
    if value(window, kAXMinimizedAttribute) as? Bool == true {
      AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    for _ in 0..<30 {
      if let focused = value(app, kAXFocusedWindowAttribute), CFEqual(focused as CFTypeRef, window)
      {
        return
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw WindowGroupError.unavailable("The requested conversation window could not receive focus.")
  }

  @MainActor static func closeRegularView(_ window: AXUIElement, of pin: ConversationPin)
    async throws
  {
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success, isRegularView(window, of: pin),
      let bounds = frame(window), let raw = value(window, kAXCloseButtonAttribute),
      !(value(window, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains(where: {
        value($0, kAXRoleAttribute) as? String == kAXSheetRole
      })
    else { throw WindowGroupError.changed }
    var close = raw as! AXUIElement
    var closingTab = false
    // A multi-tab window keeps its other tabs. Only press a close control
    // belonging to the selected tab, never guess a keyboard shortcut.
    let top = nodes(window, limit: 600) { node in
      frame(node).map { $0.minY <= bounds.minY + 70 } ?? true
    }
    for group in top where value(group, kAXRoleAttribute) as? String == "AXTabGroup" {
      let tabs =
        value(group, kAXTabsAttribute) as? [AXUIElement]
        ?? (value(group, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
          ["AXRadioButton", "AXTab"].contains(value($0, kAXRoleAttribute) as? String ?? "")
        }
      guard tabs.count > 1 else { continue }
      let selected = tabs.filter {
        value($0, kAXValueAttribute) as? Bool == true
          || value($0, kAXSelectedAttribute) as? Bool == true
      }
      guard selected.count == 1, let tab = selected.first else { throw WindowGroupError.ambiguous }
      let buttons = nodes(tab, maxDepth: 4, limit: 30).filter {
        value($0, kAXRoleAttribute) as? String == "AXButton"
          && ["close", "close tab"].contains(name($0).lowercased())
      }
      guard buttons.count == 1 else { throw WindowGroupError.ambiguous }
      close = buttons[0]
      closingTab = true
      break
    }
    guard isRegularView(window, of: pin),
      AXUIElementPerformAction(close, kAXPressAction as CFString) == .success
    else { throw WindowGroupError.changed }
    for _ in 0..<25 {
      if let list = windowList(pid),
        !list.contains(where: { CFEqual($0, window) })
          || (closingTab && isStandardWindow(window) && !name(window).isEmpty
            && !isRegularView(window, of: pin))
      {
        return
      }
      try await Task.sleep(nanoseconds: 80_000_000)
    }
    throw WindowGroupError.changed
  }

  /// Search and select inside this window. No application-wide conversation
  /// URL or Return key can be redirected into a different, grouped window.
  @MainActor static func selectCodexChat(
    _ pin: ConversationPin, title: String, in window: AXUIElement, pid: pid_t
  ) async throws {
    let destination = UUID(uuidString: pin.sessionID)
    func chatLink(_ element: AXUIElement) -> Bool {
      guard value(element, kAXRoleAttribute) as? String == "AXLink",
        let raw = value(element, kAXURLAttribute), let url = URL(string: String(describing: raw)),
        let destination, UUID(uuidString: url.lastPathComponent) == destination
      else { return false }
      let components = url.pathComponents.dropLast()
      return url.scheme == "app" && url.host == "-"
        && ["thread", "local", "threads"].contains(components.last ?? "")
    }
    let navigation = nodes(window, limit: 900).filter {
      value($0, kAXSubroleAttribute) as? String == "AXLandmarkNavigation"
        || value($0, kAXRoleDescriptionAttribute) as? String == "navigation"
    }
    for sidebar in navigation {
      if let link = nodes(sidebar, limit: 400).first(where: chatLink),
        AXUIElementPerformAction(link, kAXPressAction as CFString) == .success
      {
        return
      }
    }

    let app = AXUIElementCreateApplication(pid)
    let menu = value(app, kAXMenuBarAttribute)
    let menuItems = menu.map { nodes($0 as! AXUIElement, maxDepth: 8, limit: 650) } ?? []
    let searchMenu = menuItems.first { node in
      value(node, kAXRoleAttribute) as? String == "AXMenuItem"
        && ["search chats", "switch chat"].contains(
          name(node).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…")))
        && value(node, kAXEnabledAttribute) as? Bool != false
    }
    let searchButton =
      searchMenu
      ?? nodes(window, limit: 800).first { node in
        value(node, kAXRoleAttribute) as? String == "AXButton"
          && ["search", "search chats", "switch chat"].contains(name(node).lowercased())
      }
    guard let searchButton,
      AXUIElementPerformAction(searchButton, kAXPressAction as CFString) == .success
    else {
      throw WindowGroupError.unavailable("Codex chat search is unavailable in the separate window.")
    }
    var typed = false
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      let items = nodes(window, limit: 1600)
      func searchLabels(_ node: AXUIElement) -> [String] {
        [name(node), value(node, kAXPlaceholderValueAttribute) as? String ?? ""].map {
          $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
        }
      }
      let field = items.first { node in
        guard
          ["AXTextField", "AXComboBox", "AXSearchField"].contains(
            value(node, kAXRoleAttribute) as? String ?? "")
        else { return false }
        return (searchDialog(for: node) != nil || !searchResultLists(for: node).isEmpty)
          && searchLabels(node).contains {
            ["search chats", "search for chats", "switch chat", "search", "search chatgpt"]
              .contains(
                $0)
          }
      }
      if let field, searchLabels(field).contains("search chatgpt"),
        let dialog = searchDialog(for: field)
      {
        let tabs = nodes(dialog, limit: 300).filter {
          ["AXButton", "AXRadioButton", "AXTab"].contains(
            value($0, kAXRoleAttribute) as? String ?? "") && name($0) == "Chats"
        }
        guard tabs.count == 1,
          AXUIElementPerformAction(tabs[0], kAXPressAction as CFString) == .success
        else { throw WindowGroupError.unavailable("The Chats tab in Codex search is unavailable.") }
      } else if let field, !typed {
        guard
          AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, title as CFString)
            == .success
        else {
          throw WindowGroupError.unavailable("The Codex chat search field could not be filled.")
        }
        typed = true
      } else if let field, typed {
        let lists = searchResultLists(for: field)
        var matches: [AXUIElement] = []
        for list in lists {
          for row in nodes(list, maxDepth: 8, limit: 180) {
            let role = value(row, kAXRoleAttribute) as? String ?? ""
            guard
              ["AXRow", "AXOption", "AXStaticText", "AXButton", "AXMenuItem", "AXLink", "AXGroup"]
                .contains(role),
              name(row) == title || value(row, kAXValueAttribute) as? String == title
            else { continue }
            var target = row
            for _ in 0..<6 {
              if CFEqual(target, list) { break }
              var actions: CFArray?
              AXUIElementCopyActionNames(target, &actions)
              if (actions as? [String])?.contains(kAXPressAction) == true {
                if !matches.contains(where: { CFEqual($0, target) }) { matches.append(target) }
                break
              }
              guard let parent = value(target, kAXParentAttribute) else { break }
              target = parent as! AXUIElement
            }
          }
        }
        if matches.count == 1,
          AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success
        {
          return
        }
      }
      try await Task.sleep(nanoseconds: 120_000_000)
    }
    throw WindowGroupError.unavailable(
      "Codex could not identify this chat in the separate window's search results.")
  }

  private static func searchResultLists(for field: AXUIElement) -> [AXUIElement] {
    func isList(_ node: AXUIElement) -> Bool {
      ["AXList", "AXListBox", "AXTable", "AXMenu"].contains(
        value(node, kAXRoleAttribute) as? String ?? "")
    }
    let linked = (value(field, kAXLinkedUIElementsAttribute) as? [AXUIElement] ?? []).filter(isList)
    if !linked.isEmpty { return linked }
    return searchDialog(for: field).map { nodes($0, limit: 350).filter(isList) } ?? []
  }

  private static func searchDialog(for field: AXUIElement) -> AXUIElement? {
    var ancestor = field
    for _ in 0..<20 {
      let role = value(ancestor, kAXRoleAttribute) as? String
      let subrole = value(ancestor, kAXSubroleAttribute) as? String
      let description = value(ancestor, kAXRoleDescriptionAttribute) as? String
      if role == "AXSheet" || role == "AXPopover" || role == "AXDialog"
        || subrole == "AXApplicationDialog" || description == "dialog"
      {
        return ancestor
      }
      guard role != "AXWebArea", role != "AXWindow",
        let parent = value(ancestor, kAXParentAttribute)
      else { break }
      ancestor = parent as! AXUIElement
    }
    return nil
  }
}
