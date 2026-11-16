import AXWidgetCore
import AppKit
import ApplicationServices

/// Uses public macOS Accessibility window actions. Never changes a provider's window level.
@MainActor final class ConversationWindows {
  private struct Binding {
    let pin: ConversationPin
    let pid: pid_t
    let window: AXUIElement
  }
  private var bindings: [String: Binding] = [:]
  private var busy = false

  /// Explicit developer acceptance check; never runs during background refresh.
  /// Restores pre-existing window frames and minimizes states, and closes only pop-outs it creates.
  func verify(_ pins: [ConversationPin]) async throws -> [String: Any] {
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    let previous = NSWorkspace.shared.frontmostApplication
    let originals = Provider.allCases.flatMap { provider -> [(AXUIElement, CGRect?, Bool)] in
      NSRunningApplication.runningApplications(withBundleIdentifier: provider.bundleIdentifier)
        .flatMap { app in
          WindowAX.windows(app.processIdentifier).map {
            ($0, WindowAX.frame($0), WindowAX.value($0, kAXMinimizedAttribute) as? Bool ?? false)
          }
        }
    }
    defer {
      for binding in bindings.values
      where !originals.contains(where: { CFEqual($0.0, binding.window) }) {
        if let close = WindowAX.value(binding.window, kAXCloseButtonAttribute) {
          AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
        }
      }
      for (window, frame, minimized) in originals {
        if let frame { try? WindowAX.setFrame(window, frame) }
        AXUIElementSetAttributeValue(
          window, kAXMinimizedAttribute as CFString,
          minimized ? kCFBooleanTrue : kCFBooleanFalse)
      }
      previous?.activate(options: [])
    }
    for index in pins.indices {
      try await show(
        Array(pins.prefix(index + 1)), screen: NSScreen.main,
        arrange: true, newlyPinnedID: pins[index].id)
    }
    let windows = try pins.map { pin -> Binding in
      guard let binding = bindings[pin.id], valid(binding) else { throw WindowGroupError.changed }
      return binding
    }
    let frames = windows.map { WindowAX.frame($0.window) }
    try minimize(pins)
    try await Task.sleep(nanoseconds: 300_000_000)
    let minimized = windows.allSatisfy {
      WindowAX.value($0.window, kAXMinimizedAttribute) as? Bool == true
    }
    try await show(pins, screen: NSScreen.main)
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?
      .activate(options: [])
    try await Task.sleep(nanoseconds: 300_000_000)
    let switchedAway =
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    try await show(pins, screen: NSScreen.main)
    try await Task.sleep(nanoseconds: 300_000_000)
    let visible = windows.allSatisfy {
      WindowAX.value($0.window, kAXMinimizedAttribute) as? Bool == false && valid($0)
    }
    let preserved = zip(windows, frames).allSatisfy { WindowAX.frame($0.0.window) == $0.1 }
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    return [
      "count": pins.count, "identitiesVerified": windows.allSatisfy(valid),
      "minimizedTogether": minimized, "switchedAway": switchedAway,
      "restoredTogether": visible, "manualFramesPreserved": preserved,
      "providerForeground": pins.contains { $0.provider.bundleIdentifier == frontmost },
    ]
  }

  func forget(_ id: String) { bindings.removeValue(forKey: id) }

  func show(
    _ pins: [ConversationPin], screen: NSScreen?, arrange: Bool = false,
    newlyPinnedID: String? = nil
  ) async throws {
    guard !busy, !pins.isEmpty else { return }
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    busy = true
    defer { busy = false }
    var windows: [Binding] = []
    var opened = false
    for pin in pins {
      if let binding = bindings[pin.id], valid(binding) {
        windows.append(binding)
      } else {
        bindings.removeValue(forKey: pin.id)
        let (binding, created) = try await locateOrOpen(pin, dedicated: pin.id == newlyPinnedID)
        bindings[pin.id] = binding
        windows.append(binding)
        opened = opened || created
      }
    }
    // Raise even when the group is already unminimized but covered by Slack, etc.
    for binding in windows { try raise(binding) }
    if arrange || opened {
      try tile(windows, screen: screen ?? NSScreen.main)
    }
  }

  func minimize(_ pins: [ConversationPin]) throws {
    guard !busy else { return }
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    let windows = try pins.map { pin -> Binding in
      if bindings[pin.id] == nil,
        let app = NSRunningApplication.runningApplications(
          withBundleIdentifier: pin.provider.bundleIdentifier
        ).first
      {
        let matching = WindowAX.windows(app.processIdentifier).filter {
          WindowAX.matches($0, pin: pin)
        }
        if matching.count == 1, let window = matching.first {
          bindings[pin.id] = Binding(pin: pin, pid: app.processIdentifier, window: window)
        }
      }
      guard let binding = bindings[pin.id], valid(binding) else { throw WindowGroupError.changed }
      return binding
    }
    let states = windows.map {
      (WindowAX.value($0.window, kAXMinimizedAttribute) as? Bool) ?? false
    }
    for (index, binding) in windows.enumerated() {
      if AXUIElementSetAttributeValue(
        binding.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) != .success
      {
        for (old, state) in zip(windows.prefix(index), states) {
          AXUIElementSetAttributeValue(
            old.window, kAXMinimizedAttribute as CFString, state ? kCFBooleanTrue : kCFBooleanFalse)
        }
        throw WindowGroupError.unavailable("A pinned window could not be minimized.")
      }
    }
  }

  private func valid(_ binding: Binding) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: binding.pid), !app.isTerminated,
      app.bundleIdentifier == binding.pin.provider.bundleIdentifier
    else { return false }
    return WindowAX.matches(binding.window, pin: binding.pin)
  }

  private func raise(_ binding: Binding) throws {
    guard valid(binding) else { throw WindowGroupError.changed }
    if WindowAX.value(binding.window, "AXFullScreen") as? Bool == true {
      throw WindowGroupError.unavailable(
        "Leave full screen for the pinned conversation before showing its group.")
    }
    guard
      AXUIElementSetAttributeValue(
        binding.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
    else {
      throw WindowGroupError.unavailable("The conversation window could not be restored.")
    }
    NSRunningApplication(processIdentifier: binding.pid)?.activate(options: [])
    guard AXUIElementPerformAction(binding.window, kAXRaiseAction as CFString) == .success else {
      throw WindowGroupError.unavailable("The conversation window could not be raised.")
    }
    AXUIElementSetAttributeValue(binding.window, kAXMainAttribute as CFString, kCFBooleanTrue)
  }

  private func tile(_ windows: [Binding], screen: NSScreen?) throws {
    guard let screen, let primary = NSScreen.screens.first else { throw WindowGroupError.cannotFit }
    let visible = ConversationWindowLayout.accessibilityRect(
      screen.visibleFrame, primaryTop: primary.frame.maxY)
    let frames = try ConversationWindowLayout.frames(count: windows.count, visible: visible)
    let originals = try windows.map { binding -> CGRect in
      guard let frame = WindowAX.frame(binding.window) else { throw WindowGroupError.cannotFit }
      return frame
    }
    do {
      for (binding, frame) in zip(windows, frames) {
        try WindowAX.setFrame(binding.window, frame)
      }
      // Providers enforce their own minimum width; read back instead of overlapping silently.
      try windows.enumerated().forEach { index, binding in
        guard let actual = WindowAX.frame(binding.window),
          abs(actual.width - frames[index].width) < 3,
          abs(actual.height - frames[index].height) < 3,
          abs(actual.minX - frames[index].minX) < 3,
          abs(actual.minY - frames[index].minY) < 3
        else { throw WindowGroupError.cannotFit }
      }
    } catch {
      for (binding, frame) in zip(windows, originals) {
        try? WindowAX.setFrame(binding.window, frame)
      }
      throw error
    }
  }

  private func locateOrOpen(_ pin: ConversationPin, dedicated: Bool) async throws -> (Binding, Bool)
  {
    if !dedicated,
      let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: pin.provider.bundleIdentifier
      ).first
    {
      let matches = WindowAX.windows(running.processIdentifier).filter {
        WindowAX.matches($0, pin: pin)
      }
      if matches.count == 1, let window = matches.first {
        return (Binding(pin: pin, pid: running.processIdentifier, window: window), false)
      }
      if matches.count > 1 { throw WindowGroupError.ambiguous }
    }
    guard let url = pin.conversation.deepLink,
      let appURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: pin.provider.bundleIdentifier)
    else {
      throw WindowGroupError.unavailable(
        "\(pin.provider.label) is not installed or this conversation is unavailable.")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let running: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
      NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) {
        app, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let app {
          continuation.resume(returning: app)
        } else {
          continuation.resume(
            throwing: WindowGroupError.unavailable("The provider could not be opened."))
        }
      }
    }
    let pid = running.processIdentifier
    let deadline = Date().addingTimeInterval(15)
    var selected: AXUIElement?
    while Date() < deadline {
      let matches = WindowAX.windows(pid).filter { WindowAX.matches($0, pin: pin) }
      if matches.count == 1 {
        selected = matches[0]
        break
      }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    guard let selected else { throw WindowGroupError.ambiguous }
    let before = WindowAX.windows(pid)
    // Ask the native conversation context menu for a pop-out. No chat text is entered.
    try await WindowAX.openInNewWindow(pid: pid, window: selected, pin: pin)
    while Date() < deadline {
      let created = WindowAX.windows(pid).filter { window in
        !before.contains { CFEqual($0, window) } && WindowAX.matches(window, pin: pin)
      }
      if created.count == 1, let window = created.first {
        return (Binding(pin: pin, pid: pid, window: window), true)
      }
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    throw WindowGroupError.unavailable(
      "\(pin.provider.label) did not open a separate window for this conversation. No other conversation was added to the group."
    )
  }
}

/// Bounded, provider-scoped navigation. Never searches or presses chat answer/approval controls.
enum WindowAX {
  static func value(_ element: AXUIElement, _ name: String) -> Any? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else {
      return nil
    }
    return result
  }
  static func windows(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    return value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
  }
  static func nodes(_ element: AXUIElement, maxDepth: Int = 24, limit: Int = 2400) -> [AXUIElement]
  {
    let deadline = Date().addingTimeInterval(1.5)
    var result: [AXUIElement] = []
    func visit(_ node: AXUIElement, _ depth: Int) {
      guard depth <= maxDepth, result.count < limit, Date() < deadline else { return }
      result.append(node)
      for child in value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        visit(child, depth + 1)
      }
    }
    visit(element, 0)
    return result
  }
  static func name(_ element: AXUIElement) -> String {
    (value(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? value(element, kAXDescriptionAttribute) as? String ?? ""
  }
  static func matches(_ window: AXUIElement, pin: ConversationPin) -> Bool {
    guard value(window, kAXRoleAttribute) as? String == kAXWindowRole else { return false }
    let ids = [pin.sessionID, pin.desktopSessionID].compactMap { $0 }
    for node in [window]
      + nodes(window, maxDepth: 8, limit: 100).filter({
        value($0, kAXRoleAttribute) as? String == "AXWebArea"
      })
    {
      for attr in [kAXDocumentAttribute, "AXURL"] {
        if let url = value(node, attr),
          ids.contains(where: { String(describing: url).contains($0) })
        {
          return true
        }
      }
    }
    // Conversation titles are mutable and nonunique. They are never identity evidence.
    return false
  }
  static func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
      CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID(),
      CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
      AXValueGetValue(s as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: point, size: size)
  }
  static func setFrame(_ element: AXUIElement, _ frame: CGRect) throws {
    var point = frame.origin
    var size = frame.size
    guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size),
      AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) == .success,
      AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) == .success
    else { throw WindowGroupError.cannotFit }
  }
  private static func press(_ nodes: [AXUIElement], names: Set<String>) -> Bool {
    let matches = nodes.filter { node in
      ["AXMenuItem", "AXButton"].contains(value(node, kAXRoleAttribute) as? String ?? "")
        && names.contains(name(node).lowercased())
        && value(node, kAXEnabledAttribute) as? Bool != false
    }
    return matches.count == 1
      && AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success
  }
  static func openInNewWindow(pid: pid_t, window: AXUIElement, pin: ConversationPin) async throws {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    // Prefer an exposed native menu action for the selected conversation.
    let direct: Set<String> = [
      "open in new window", "open in a new window", "open session in new window",
    ]
    if let menu = value(app, kAXMenuBarAttribute) {
      if press(nodes(menu as! AXUIElement, maxDepth: 8, limit: 500), names: direct) { return }
    }
    let controls = nodes(window).filter { node in
      guard
        ["AXLink", "AXRow", "AXButton"].contains(value(node, kAXRoleAttribute) as? String ?? "")
      else { return false }
      return true
    }
    let linked = controls.filter { node in
      if let url = value(node, "AXURL"),
        [pin.sessionID, pin.desktopSessionID].compactMap({ $0 }).contains(where: {
          String(describing: url).contains($0)
        })
      {
        return true
      }
      return false
    }
    let candidates = linked.isEmpty ? controls.filter { name($0) == pin.title } : linked
    guard candidates.count == 1, let row = candidates.first else {
      throw WindowGroupError.ambiguous
    }
    if AXUIElementPerformAction(row, kAXShowMenuAction as CFString) != .success {
      guard let rect = frame(row), rect.width > 0, rect.height > 0 else {
        throw WindowGroupError.ambiguous
      }
      let point = CGPoint(x: rect.midX, y: rect.midY)
      for kind in [CGEventType.rightMouseDown, .rightMouseUp] {
        CGEvent(
          mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .right)?
          .postToPid(pid)
      }
    }
    for _ in 0..<15 {
      try await Task.sleep(nanoseconds: 100_000_000)
      let tree = nodes(app)
      if press(tree, names: direct) { return }
      if press(tree, names: ["open in", "open in…", "open in..."]) {
        try await Task.sleep(nanoseconds: 150_000_000)
        if press(nodes(app), names: ["new window", "open in new window"]) { return }
      }
    }
    throw WindowGroupError.unavailable(
      "\(pin.provider.label)'s Open in New Window action is unavailable. Open this conversation in a separate window and pin it again."
    )
  }

  static func diagnostics() -> [[String: Any]] {
    Provider.allCases.map { provider in
      let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: provider.bundleIdentifier
      ).first
      var result: [String: Any] = [
        "provider": provider.rawValue, "running": app != nil,
        "windows": app.map {
          windows($0.processIdentifier).map { window -> [String: Any] in
            [
              "title": name(window),
              "document": String(describing: value(window, kAXDocumentAttribute) ?? ""),
              "frame": frame(window).map { NSStringFromRect($0) } ?? "",
              "minimized": value(window, kAXMinimizedAttribute) as? Bool ?? false,
            ]
          }
        } ?? [],
      ]
      if let app {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        if let menu = value(element, kAXMenuBarAttribute) {
          result["menuItems"] = nodes(menu as! AXUIElement, maxDepth: 8, limit: 500).compactMap {
            node -> String? in
            guard value(node, kAXRoleAttribute) as? String == "AXMenuItem" else { return nil }
            return name(node)
          }
        }
        result["navigation"] = windows(app.processIdentifier).map { window in
          nodes(window).compactMap { node -> [String: String]? in
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            guard ["AXWebArea", "AXLink", "AXRow"].contains(role) else { return nil }
            return [
              "role": role, "name": name(node),
              "url": String(describing: value(node, "AXURL") ?? ""),
            ]
          }
        }
      }
      return result
    }
  }
}
