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
  private struct Bookmark: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(_ rect: CGRect) {
      x = rect.minX
      y = rect.minY
      width = rect.width
      height = rect.height
    }
    func matches(_ rect: CGRect?) -> Bool {
      guard let rect else { return false }
      return abs(x - rect.minX) < 3 && abs(y - rect.minY) < 3
        && abs(width - rect.width) < 3 && abs(height - rect.height) < 3
    }
  }
  private var bookmarks: [String: Bookmark] = [:]
  private let persist: Bool
  init(persist: Bool = true) {
    self.persist = persist
    if persist, let data = UserDefaults.standard.data(forKey: "conversationWindowFrames") {
      bookmarks = (try? JSONDecoder().decode([String: Bookmark].self, from: data)) ?? [:]
    }
  }
  func remember() {
    for (id, binding) in bindings {
      if let frame = WindowAX.frame(binding.window) { bookmarks[id] = Bookmark(frame) }
    }
    if persist, let data = try? JSONEncoder().encode(bookmarks) {
      UserDefaults.standard.set(data, forKey: "conversationWindowFrames")
    }
  }
  private func existing(_ pin: ConversationPin, pid: pid_t) -> AXUIElement? {
    let matching = WindowAX.windows(pid).filter { WindowAX.matches($0, pin: pin) }
    if matching.count == 1 { return matching.first }
    let recorded = matching.filter { bookmarks[pin.id]?.matches(WindowAX.frame($0)) == true }
    return recorded.count == 1 ? recorded.first : nil
  }

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
    let restarted = ConversationWindows(persist: false)
    restarted.bookmarks = bookmarks
    try await restarted.show(pins, screen: NSScreen.main)
    let reused = pins.allSatisfy { pin in
      guard let old = bindings[pin.id], let new = restarted.bindings[pin.id] else { return false }
      return CFEqual(old.window, new.window)
    }
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    return [
      "count": pins.count, "identitiesVerified": windows.allSatisfy(valid),
      "minimizedTogether": minimized, "switchedAway": switchedAway,
      "restoredTogether": visible, "manualFramesPreserved": preserved,
      "providerForeground": pins.contains { $0.provider.bundleIdentifier == frontmost },
      "reusedAfterWidgetRestart": reused,
    ]
  }

  func forget(_ id: String) {
    bindings.removeValue(forKey: id)
    bookmarks.removeValue(forKey: id)
    remember()
  }

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
    remember()
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
        if let window = existing(pin, pid: app.processIdentifier) {
          bindings[pin.id] = Binding(pin: pin, pid: app.processIdentifier, window: window)
        }
      }
      guard let binding = bindings[pin.id], valid(binding) else { throw WindowGroupError.changed }
      return binding
    }
    let states = windows.map {
      (WindowAX.value($0.window, kAXMinimizedAttribute) as? Bool) ?? false
    }
    remember()
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
      if let window = existing(pin, pid: running.processIdentifier) {
        return (Binding(pin: pin, pid: running.processIdentifier, window: window), false)
      }
      if WindowAX.windows(running.processIdentifier).filter({ WindowAX.matches($0, pin: pin) })
        .count > 1
      {
        throw WindowGroupError.ambiguous
      }
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
    if pin.provider == .codex {
      let running = try await NSWorkspace.shared.openApplication(
        at: appURL, configuration: configuration)
      let pid = running.processIdentifier
      let before = WindowAX.windows(pid)
      try WindowAX.newCodexWindow(pid)
      let deadline = Date().addingTimeInterval(10)
      var newWindow: AXUIElement?
      while Date() < deadline {
        let created = WindowAX.windows(pid).filter { window in
          !before.contains { CFEqual($0, window) }
        }
        if created.count == 1 {
          newWindow = created.first
          break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      guard let newWindow else {
        throw WindowGroupError.unavailable("Codex could not create a new window.")
      }
      AXUIElementPerformAction(newWindow, kAXRaiseAction as CFString)
      AXUIElementSetAttributeValue(newWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
      try await Task.sleep(nanoseconds: 200_000_000)
      let navigation = NSWorkspace.OpenConfiguration()
      navigation.activates = false
      _ = try await NSWorkspace.shared.open(
        [url], withApplicationAt: appURL, configuration: navigation)
      let navigationDeadline = Date().addingTimeInterval(10)
      while Date() < navigationDeadline {
        if WindowAX.matches(newWindow, pin: pin) {
          return (Binding(pin: pin, pid: pid, window: newWindow), true)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      throw WindowGroupError.unavailable(
        "Codex opened a window but did not show the requested conversation.")
    }
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
    let popoutDeadline = Date().addingTimeInterval(10)
    while Date() < popoutDeadline {
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
    // Electron documents this opt-in for native assistive clients. It exposes
    // the renderer tree without enabling VoiceOver or changing system settings.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    return value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
  }
  static func nodes(_ element: AXUIElement, maxDepth: Int = 56, limit: Int = 6000) -> [AXUIElement]
  {
    let deadline = Date().addingTimeInterval(2)
    var result: [AXUIElement] = []
    var pending: [(AXUIElement, Int)] = [(element, 0)]
    var cursor = 0
    // Breadth first: a long transcript must not hide later sidebar/menu siblings.
    while cursor < pending.count, result.count < limit, Date() < deadline {
      let (node, depth) = pending[cursor]
      cursor += 1
      result.append(node)
      if depth < maxDepth {
        let children = value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        pending.append(
          contentsOf: children.prefix(max(0, limit * 2 - pending.count)).map { ($0, depth + 1) })
      }
    }
    return result
  }
  static func name(_ element: AXUIElement) -> String {
    (value(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? value(element, kAXDescriptionAttribute) as? String ?? ""
  }
  static func matches(_ window: AXUIElement, pin: ConversationPin) -> Bool {
    guard value(window, kAXRoleAttribute) as? String == kAXWindowRole else { return false }
    if pin.provider == .codex {
      guard let title = CodexWindowIdentity.title(sessionID: pin.sessionID) else { return false }
      return name(window) == title
    }
    guard let session = pin.desktopSessionID else { return false }
    var pending: [(AXUIElement, Int)] = [(window, 0)]
    var cursor = 0
    let deadline = Date().addingTimeInterval(1)
    while cursor < pending.count, cursor < 500, Date() < deadline {
      let (node, depth) = pending[cursor]
      cursor += 1
      if value(node, kAXRoleAttribute) as? String == "AXWebArea",
        let raw = value(node, "AXURL"), let url = URL(string: String(describing: raw)),
        url.host == "claude.ai",
        url.pathComponents.contains("epitaxy") || url.pathComponents.contains("code")
      {
        // The outer native conversation document is authoritative, not links or artifact content.
        return url.pathComponents.contains(session)
      }
      if depth < 24 {
        let children = value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        pending.append(
          contentsOf: children.prefix(max(0, 1000 - pending.count)).map { ($0, depth + 1) })
      }
    }
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
  private static func press(
    _ nodes: [AXUIElement], names: Set<String>, roles: Set<String> = ["AXMenuItem"]
  ) -> Bool {
    let matches = nodes.filter { node in
      roles.contains(value(node, kAXRoleAttribute) as? String ?? "")
        && names.contains(name(node).lowercased())
        && value(node, kAXEnabledAttribute) as? Bool != false
    }
    return matches.count == 1
      && AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success
  }
  static func newCodexWindow(_ pid: pid_t) throws {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    guard let raw = value(app, kAXMenuBarAttribute) else { throw WindowGroupError.ambiguous }
    let bar = raw as! AXUIElement
    let files = (value(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
      name($0) == "File"
    }
    guard files.count == 1, let file = files.first,
      press(nodes(file, maxDepth: 8, limit: 200), names: ["new window"])
    else {
      throw WindowGroupError.unavailable("Codex's File → New Window action is unavailable.")
    }
  }
  private static func searchPaletteScope(_ field: AXUIElement) -> AXUIElement? {
    var current = field
    for _ in 0..<6 {
      guard let raw = value(current, kAXParentAttribute) else { return nil }
      current = raw as! AXUIElement
      let role = value(current, kAXRoleAttribute) as? String ?? ""
      let subrole = value(current, kAXSubroleAttribute) as? String ?? ""
      if ["AXWindow", "AXWebArea"].contains(role) { return nil }
      if role == "AXDialog" || subrole == "AXDialog" { return current }
      if nodes(current, maxDepth: 6, limit: 250).contains(where: {
        ["AXListBox", "AXList", "AXMenu"].contains(value($0, kAXRoleAttribute) as? String ?? "")
      }) {
        return current
      }
    }
    return nil
  }
  private static func key(_ pid: pid_t, code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
      event?.flags = flags
      event?.postToPid(pid)
    }
  }
  static func openInNewWindow(pid: pid_t, window: AXUIElement, pin: ConversationPin) async throws {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    let direct: Set<String> = [
      "open in new window", "open in a new window", "open session in new window",
      "open current session in new window",
    ]
    func menu(_ labels: Set<String>) -> Bool {
      guard let bar = value(app, kAXMenuBarAttribute) else { return false }
      return press(nodes(bar as! AXUIElement, maxDepth: 8, limit: 600), names: labels)
    }
    if menu(direct) { return }
    let bounds = frame(window)
    let header = nodes(window).filter { node in
      guard let bounds, let rect = frame(node) else { return false }
      return rect.minY < bounds.minY + 65 && rect.height <= 40
    }
    let shownSidebar =
      press(header, names: ["show sidebar"], roles: ["AXButton"])
      || menu(["show sidebar"])
    defer {
      if shownSidebar {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        if !press(
          nodes(window).filter { node in
            guard let bounds, let rect = frame(node) else { return false }
            return rect.minY < bounds.minY + 65 && rect.height <= 40
          }, names: ["hide sidebar"], roles: ["AXButton"])
        {
          _ = menu(["hide sidebar"])
        }
      }
    }
    if shownSidebar { try await Task.sleep(nanoseconds: 250_000_000) }
    let controls = nodes(window).filter { node in
      guard
        ["AXLink", "AXRow", "AXButton"].contains(value(node, kAXRoleAttribute) as? String ?? ""),
        let bounds, let rect = frame(node)
      else { return false }
      // Only full sidebar rows; chat answer buttons and the composer are out of scope.
      return rect.minX >= bounds.minX && rect.maxX <= bounds.minX + 360
        && rect.width >= 100 && rect.height > 0 && rect.height < 120
    }
    let linked = controls.filter { node in
      guard let url = value(node, "AXURL") else { return false }
      return [pin.sessionID, pin.desktopSessionID].compactMap { $0 }.contains {
        String(describing: url).contains($0)
      }
    }
    var candidates = linked.isEmpty ? controls.filter { name($0) == pin.title } : linked
    if candidates.isEmpty, let bounds = frame(window) {
      candidates = controls.filter { node in
        guard let rect = frame(node), rect.minX < bounds.minX + 320, rect.height < 120 else {
          return false
        }
        return name(node).hasPrefix(pin.title + " ")
      }
    }
    if candidates.count == 1, let row = candidates.first, let rect = frame(row),
      rect.width > 0, rect.height > 0
    {
      let point = CGPoint(x: rect.midX, y: rect.midY)
      if pin.provider == .claude {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
          throw WindowGroupError.unavailable(
            "Bring Claude to the front before opening its conversation window.")
        }
        let cursor = CGEvent(source: nil)?.location
        // Claude's documented Command-click opens an existing session in its own window.
        for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
          let event = CGEvent(
            mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)
          event?.flags = .maskCommand
          event?.post(tap: .cghidEventTap)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        if let cursor { CGWarpMouseCursorPosition(cursor) }
        return
      }
      if AXUIElementPerformAction(row, kAXShowMenuAction as CFString) != .success {
        for kind in [CGEventType.rightMouseDown, .rightMouseUp] {
          CGEvent(
            mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .right)?
            .postToPid(pid)
        }
      }
      for _ in 0..<5 {
        try await Task.sleep(nanoseconds: 100_000_000)
        if press(nodes(app), names: direct) { return }
        if press(nodes(app), names: ["open in", "open in…", "open in..."]) {
          try await Task.sleep(nanoseconds: 150_000_000)
          if press(nodes(app), names: ["new window", "open in new window"]) { return }
        }
      }
      key(pid, code: 53)
    }
    // A collapsed sidebar may hide its row. Use only the native search palette;
    // never type into a chat composer, and never invoke a New Session action.
    key(pid, code: 40, flags: .maskCommand)
    for _ in 0..<5 {
      try await Task.sleep(nanoseconds: 150_000_000)
      let fields = nodes(app).filter { node in
        guard
          ["AXComboBox", "AXTextField"].contains(value(node, kAXRoleAttribute) as? String ?? "")
        else { return false }
        let label = name(node) + " " + (value(node, "AXPlaceholderValue") as? String ?? "")
        return label.lowercased().contains("search")
      }
      if fields.count == 1, let field = fields.first, let scope = searchPaletteScope(field),
        AXUIElementSetAttributeValue(
          field, kAXValueAttribute as CFString, "Open in new window" as CFString) == .success
      {
        for _ in 0..<8 {
          try await Task.sleep(nanoseconds: 150_000_000)
          if press(nodes(scope), names: direct, roles: ["AXMenuItem", "AXRow", "AXButton"]) {
            return
          }
        }
        break
      }
    }
    key(pid, code: 53)
    throw WindowGroupError.unavailable(
      "\(pin.provider.label)'s Open in New Window action is unavailable. No new conversation was created."
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
            guard
              [
                "AXWebArea", "AXLink", "AXRow", "AXButton", "AXMenuItem", "AXComboBox",
                "AXTextField",
              ].contains(role)
            else { return nil }
            return [
              "role": role, "name": name(node),
              "url": String(describing: value(node, "AXURL") ?? ""),
              "identifier": String(describing: value(node, kAXIdentifierAttribute) ?? ""),
              "domID": String(describing: value(node, "AXDOMIdentifier") ?? ""),
              "placeholder": String(describing: value(node, "AXPlaceholderValue") ?? ""),
              "frame": frame(node).map { NSStringFromRect($0) } ?? "",
            ]
          }
        }
      }
      return result
    }
  }
}
