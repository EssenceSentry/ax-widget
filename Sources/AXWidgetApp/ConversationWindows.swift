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
    if pin.provider == .claude {
      let popouts = matching.filter { WindowAX.isClaudePopout($0, pin: pin) }
      if popouts.count == 1 { return popouts.first }
      let recorded = popouts.filter { bookmarks[pin.id]?.matches(WindowAX.frame($0)) == true }
      return recorded.count == 1 ? recorded.first : nil
    }
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
        arrange: true)
    }
    let windows = try pins.map { pin -> Binding in
      guard let binding = bindings[pin.id], valid(binding) else { throw WindowGroupError.changed }
      return binding
    }
    // Simulate a manual adjustment so a hidden re-tile cannot pass preservation.
    if let first = windows.first, var moved = WindowAX.frame(first.window) {
      moved.origin.x += 3
      moved.origin.y += 3
      try WindowAX.setFrame(first.window, moved)
    }
    let frames = windows.map { WindowAX.frame($0.window) }
    try minimize(pins)
    let minimized = try await waitForNativeTransition {
      windows.allSatisfy { WindowAX.value($0.window, kAXMinimizedAttribute) as? Bool == true }
    }
    try await show(pins, screen: NSScreen.main)
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?
      .activate(options: [])
    let switchedAway = try await waitForNativeTransition {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }
    try await show(pins, screen: NSScreen.main)
    let visible = try await waitForNativeTransition {
      windows.allSatisfy {
        WindowAX.value($0.window, kAXMinimizedAttribute) as? Bool == false && valid($0)
      }
    }
    let preserved = zip(windows, frames).allSatisfy { WindowAX.frame($0.0.window) == $0.1 }
    let restarted = ConversationWindows(persist: false)
    restarted.bookmarks = bookmarks
    try await restarted.show(pins, screen: NSScreen.main)
    let reused = pins.allSatisfy { pin in
      guard let old = bindings[pin.id], let new = restarted.bindings[pin.id] else { return false }
      return CFEqual(old.window, new.window)
    }
    let providerForeground = try await waitForNativeTransition {
      pins.contains {
        $0.provider.bundleIdentifier == NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      }
    }
    let stacking = WindowAX.stacking(windows.map { ($0.pid, $0.window) })
    if let value = ProcessInfo.processInfo.environment["AX_WIDGET_VERIFY_HOLD_SECONDS"],
      let seconds = Double(value), seconds > 0, seconds <= 10
    {
      let phase: [String: Any] = [
        "phase": "ready",
        "windows": windows.map { binding in
          [
            "pid": binding.pid,
            "frame": WindowAX.frame(binding.window).map { NSStringFromRect($0) } ?? "",
          ] as [String: Any]
        },
      ]
      if let data = try? JSONSerialization.data(withJSONObject: phase) {
        FileHandle.standardOutput.write(data + Data([10]))
      }
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    return [
      "count": pins.count, "identitiesVerified": windows.allSatisfy(valid),
      "minimizedTogether": minimized, "switchedAway": switchedAway,
      "restoredTogether": visible, "manualFramesPreserved": preserved,
      "providerForeground": providerForeground,
      "reusedAfterWidgetRestart": reused,
      "raisedTogether": stacking.raised.map { $0 as Any } ?? NSNull(),
      "normalWindowLevels": stacking.normal.map { $0 as Any } ?? NSNull(),
    ]
  }

  private func waitForNativeTransition(_ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(3)
    repeat {
      if condition() { return true }
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    return condition()
  }

  func forget(_ id: String) {
    bindings.removeValue(forKey: id)
    bookmarks.removeValue(forKey: id)
    remember()
  }

  func show(
    _ pins: [ConversationPin], screen: NSScreen?, arrange: Bool = false
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
        let (binding, created) = try await locateOrOpen(pin)
        bindings[pin.id] = binding
        windows.append(binding)
        opened = opened || created
      }
    }
    // Activate once, then raise every group window. Activating each provider in
    // turn could also raise an unpinned main window over earlier group members.
    if let last = windows.last {
      NSRunningApplication(processIdentifier: last.pid)?.activate(options: [])
      AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(last.pid),
        kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    for binding in windows { try raise(binding) }
    if arrange || opened {
      for binding in windows {
        await WindowAX.hideSidebar(binding.window, pid: binding.pid, provider: binding.pin.provider)
      }
      try await tile(windows, screen: screen ?? NSScreen.main)
      for binding in windows { try raise(binding) }
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
    guard AXUIElementPerformAction(binding.window, kAXRaiseAction as CFString) == .success else {
      throw WindowGroupError.unavailable("The conversation window could not be raised.")
    }
    AXUIElementSetAttributeValue(binding.window, kAXMainAttribute as CFString, kCFBooleanTrue)
  }

  private func tile(_ windows: [Binding], screen: NSScreen?) async throws {
    guard let screen, let primary = NSScreen.screens.first else { throw WindowGroupError.cannotFit }
    let visible = ConversationWindowLayout.accessibilityRect(
      screen.visibleFrame, primaryTop: primary.frame.maxY)
    let originals = try windows.map { binding -> CGRect in
      guard let frame = WindowAX.frame(binding.window) else { throw WindowGroupError.cannotFit }
      return frame
    }
    var minimums = Array(repeating: CGFloat(320), count: windows.count)
    do {
      for _ in 0...windows.count {
        let frames = try ConversationWindowLayout.frames(
          minimumWidths: minimums, visible: visible, gap: 6, padding: 6)
        for (binding, frame) in zip(windows, frames) {
          try WindowAX.setFrame(binding.window, frame)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let actual = windows.compactMap { WindowAX.frame($0.window) }
        guard actual.count == frames.count else { throw WindowGroupError.cannotFit }
        WindowAX.lastLayout = zip(windows.indices, frames).map { index, target in
          [
            "provider": windows[index].pin.provider.rawValue, "target": NSStringFromRect(target),
            "actual": NSStringFromRect(actual[index]),
          ]
        }
        var constrained = false
        var exact = true
        for index in frames.indices {
          if actual[index].width > frames[index].width + 2 {
            minimums[index] = max(minimums[index], ceil(actual[index].width))
            constrained = true
          }
          if abs(actual[index].width - frames[index].width) > 2
            || abs(actual[index].height - frames[index].height) > 2
            || abs(actual[index].minX - frames[index].minX) > 2
            || abs(actual[index].minY - frames[index].minY) > 2
          {
            exact = false
          }
        }
        if exact { return }
        if !constrained { throw WindowGroupError.cannotFit }
      }
      throw WindowGroupError.cannotFit
    } catch {
      for (binding, frame) in zip(windows, originals) {
        try? WindowAX.setFrame(binding.window, frame)
      }
      throw error
    }
  }

  private func locateOrOpen(_ pin: ConversationPin) async throws -> (Binding, Bool) {
    if pin.provider == .codex, CodexWindowIdentity.title(sessionID: pin.sessionID) == nil {
      throw WindowGroupError.unavailable(
        "Codex cannot identify this chat by a unique title. Give it a distinct title before pinning it."
      )
    }
    if let running = NSRunningApplication.runningApplications(
      withBundleIdentifier: pin.provider.bundleIdentifier
    ).first {
      if let window = existing(pin, pid: running.processIdentifier) {
        return (Binding(pin: pin, pid: running.processIdentifier, window: window), false)
      }
      if WindowAX.windows(running.processIdentifier).filter({
        WindowAX.matches($0, pin: pin)
          && (pin.provider != .claude || WindowAX.isClaudePopout($0, pin: pin))
      })
      .count > 1 {
        throw WindowGroupError.ambiguous
      }
    }
    if pin.provider == .claude,
      pin.desktopSessionID.flatMap({ ClaudeWindowIdentity.title(desktopSessionID: $0) }) == nil
    {
      throw WindowGroupError.unavailable(
        "Claude cannot identify this chat by a unique title. Give it a distinct title before pinning it."
      )
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
    let protected = bindings.values.filter { $0.pin.provider == .claude }
    func restoreProtected() async {
      for binding in protected where !valid(binding) {
        guard let original = binding.pin.conversation.deepLink else { continue }
        AXUIElementPerformAction(binding.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(binding.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let restore = NSWorkspace.OpenConfiguration()
        restore.activates = false
        _ = try? await NSWorkspace.shared.open(
          [original], withApplicationAt: appURL, configuration: restore)
        for _ in 0..<20 {
          if valid(binding) { break }
          try? await Task.sleep(nanoseconds: 100_000_000)
        }
      }
    }
    do {
      let running = try await NSWorkspace.shared.open(
        [url], withApplicationAt: appURL, configuration: configuration)
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
      // Every Claude pin gets the compact, sidebar-free native conversation
      // window. The main app remains available for browsing other sessions.
      let before = WindowAX.windows(pid)
      try await WindowAX.openInNewWindow(pid: pid, window: selected, pin: pin)
      let popoutDeadline = Date().addingTimeInterval(10)
      var inspected = false
      while Date() < popoutDeadline {
        let added = WindowAX.windows(pid).filter { window in
          !before.contains { CFEqual($0, window) }
        }
        if !added.isEmpty && !inspected {
          inspected = true
          for window in added {
            WindowAX.lastNavigation.append(
              "newWindow=\(WindowAX.name(window)) role=\(WindowAX.value(window, kAXRoleAttribute) ?? "")"
            )
            WindowAX.lastNavigation += WindowAX.nodes(window).filter {
              WindowAX.value($0, kAXRoleAttribute) as? String == "AXWebArea"
            }
            .map { "document=\(WindowAX.value($0, "AXURL") ?? "")" }
          }
        }
        let created = added.filter { WindowAX.matches($0, pin: pin) }
        if created.count == 1, let window = created.first {
          await restoreProtected()
          return (Binding(pin: pin, pid: pid, window: window), true)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      throw WindowGroupError.unavailable(
        "Claude did not open a separate window for this conversation. No other conversation was added to the group."
      )
    } catch {
      await restoreProtected()
      throw error
    }

  }
}

/// Bounded, provider-scoped navigation. Never searches or presses chat answer/approval controls.
enum WindowAX {
  static var lastLayout: [[String: String]] = []
  @MainActor static func hideSidebar(_ window: AXUIElement, pid: pid_t, provider: Provider) async {
    guard let bounds = frame(window) else { return }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    try? await Task.sleep(nanoseconds: 100_000_000)
    var hit: AXUIElement?
    let x = bounds.minX + (provider == .codex ? 170 : 98)
    guard
      AXUIElementCopyElementAtPosition(
        AXUIElementCreateSystemWide(), Float(x), Float(bounds.minY + 22), &hit) == .success,
      var current = hit
    else { return }
    for _ in 0..<6 {
      var owner: pid_t = 0
      guard AXUIElementGetPid(current, &owner) == .success, owner == pid else { return }
      if value(current, kAXRoleAttribute) as? String == "AXButton" {
        let label = name(current).lowercased()
        if label == "hide sidebar" {
          AXUIElementPerformAction(current, kAXPressAction as CFString)
          try? await Task.sleep(nanoseconds: 150_000_000)
          return
        }
        if label == "show sidebar" { return }
      }
      guard let parent = value(current, kAXParentAttribute) else { return }
      current = parent as! AXUIElement
    }
  }
  static func stacking(_ windows: [(pid_t, AXUIElement)]) -> (raised: Bool?, normal: Bool?) {
    guard
      let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return (nil, nil) }
    let rows = raw.compactMap { row -> (pid_t, CGRect, Int)? in
      guard let pidNumber = row[kCGWindowOwnerPID as String] as? NSNumber,
        let bounds = row[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        let level = row[kCGWindowLayer as String] as? Int
      else { return nil }
      return (pidNumber.int32Value, rect, level)
    }
    func close(_ a: CGRect, _ b: CGRect) -> Bool {
      abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3
        && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
    let indices = windows.compactMap { pid, window -> Int? in
      guard let rect = frame(window) else { return nil }
      return rows.firstIndex { $0.0 == pid && close($0.1, rect) }
    }
    guard indices.count == windows.count else { return (nil, nil) }
    let group = Set(indices)
    let raised = indices.allSatisfy { index in
      !rows.prefix(index).enumerated().contains { other, row in
        guard row.2 == 0, !group.contains(other) else { return false }
        let overlap = row.1.intersection(rows[index].1)
        return !overlap.isNull && overlap.width * overlap.height > 100
      }
    }
    return (raised, indices.allSatisfy { rows[$0].2 == 0 })
  }
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
  static func nodes(
    _ element: AXUIElement, maxDepth: Int = 56, limit: Int = 6000,
    include: ((AXUIElement) -> Bool)? = nil
  ) -> [AXUIElement] {
    let deadline = Date().addingTimeInterval(2)
    var result: [AXUIElement] = []
    var pending: [(AXUIElement, Int)] = [(element, 0)]
    var cursor = 0
    var visited: [CFHashCode: [AXUIElement]] = [:]
    // Breadth first: a long transcript must not hide later sidebar/menu siblings.
    while cursor < pending.count, result.count < limit, Date() < deadline {
      let (node, depth) = pending[cursor]
      cursor += 1
      let hash = CFHash(node)
      if visited[hash]?.contains(where: { CFEqual($0, node) }) == true { continue }
      visited[hash, default: []].append(node)
      if include?(node) == false { continue }
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
    if isClaudePopout(window, pin: pin) { return true }
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
  static func isClaudePopout(_ window: AXUIElement, pin: ConversationPin) -> Bool {
    guard pin.provider == .claude, let id = pin.desktopSessionID,
      let title = ClaudeWindowIdentity.title(desktopSessionID: id), name(window) == title,
      let bounds = frame(window)
    else { return false }
    let header = nodes(
      window, maxDepth: 56, limit: 1000,
      include: { node in
        guard let rect = frame(node) else { return true }
        return rect.minY < bounds.minY + 65 || rect.height > bounds.height / 2
      })
    let blankDocument = header.contains {
      value($0, kAXRoleAttribute) as? String == "AXWebArea"
        && String(describing: value($0, "AXURL") ?? "") == "about:blank"
    }
    let returnButton = header.contains { node in
      guard value(node, kAXRoleAttribute) as? String == "AXButton",
        name(node) == "Open in main window", let rect = frame(node)
      else { return false }
      return rect.minY < bounds.minY + 65 && rect.height <= 40
    }
    return blankDocument && returnButton
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
    guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else {
      throw WindowGroupError.cannotFit
    }
    // Electron can clamp an enlargement to the space beside the old origin.
    // Move first, resize, then repeat the move after any native constraints.
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
    guard AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) == .success,
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
  static var lastNavigation: [String] = []
  private static func navigationNodes(_ window: AXUIElement, bounds: CGRect?) -> [AXUIElement] {
    nodes(
      window,
      include: { node in
        guard let bounds, let rect = frame(node) else { return true }
        // Conversation transcripts can contain thousands of nodes. The navigation
        // column starts at the window's left edge; skip the separate wide chat pane.
        return !(rect.minX >= bounds.minX + 180 && rect.width > 400)
      })
  }
  static func openInNewWindow(pid: pid_t, window: AXUIElement, pin: ConversationPin) async throws {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    lastNavigation = []
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    try await Task.sleep(nanoseconds: 150_000_000)
    let bounds = frame(window)
    func header(_ labels: Set<String>) -> Bool {
      if let bounds {
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(
          AXUIElementCreateSystemWide(), Float(bounds.minX + 98), Float(bounds.minY + 22), &hit)
          == .success,
          var current = hit
        {
          for _ in 0..<6 {
            var owner: pid_t = 0
            guard AXUIElementGetPid(current, &owner) == .success else { break }
            lastNavigation.append(
              "toolbarHit=\(value(current, kAXRoleAttribute) as? String ?? ""):\(name(current)) owner=\(owner)"
            )
            guard owner == pid else { break }
            let label = name(current).lowercased()
            if value(current, kAXRoleAttribute) as? String == "AXButton",
              ["show sidebar", "hide sidebar"].contains(label)
            {
              return labels.contains(label)
                && AXUIElementPerformAction(current, kAXPressAction as CFString) == .success
            }
            guard let parent = value(current, kAXParentAttribute) else { break }
            current = parent as! AXUIElement
          }
        }
      }
      let controls = navigationNodes(window, bounds: bounds).filter { node in
        guard let bounds, let rect = frame(node) else { return false }
        return rect.minY < bounds.minY + 65 && rect.height <= 40 && rect.minX < bounds.minX + 200
      }
      return press(controls, names: labels, roles: ["AXButton"])
    }
    let shownSidebar = header(["show sidebar"])
    let cursor = CGEvent(source: nil)?.location
    defer {
      if shownSidebar {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = header(["hide sidebar"])
      }
      if let cursor { CGWarpMouseCursorPosition(cursor) }
    }
    if shownSidebar { try await Task.sleep(nanoseconds: 250_000_000) }
    let controls = navigationNodes(window, bounds: bounds).filter { node in
      guard
        ["AXLink", "AXRow", "AXButton"].contains(value(node, kAXRoleAttribute) as? String ?? ""),
        let bounds, let rect = frame(node)
      else { return false }
      return rect.minX >= bounds.minX && rect.maxX <= bounds.minX + 360
        && rect.minY >= bounds.minY + 65 && rect.width >= 100 && rect.height > 0
        && rect.height < 120
    }
    guard let id = pin.desktopSessionID,
      let currentTitle = ClaudeWindowIdentity.title(desktopSessionID: id)
    else { throw WindowGroupError.ambiguous }
    let candidates = controls.filter {
      name($0) == currentTitle || name($0).hasPrefix(currentTitle + " ")
    }
    lastNavigation +=
      ["expected=\(currentTitle)", "sidebarOpened=\(shownSidebar)"]
      + Array(controls.prefix(30)).map {
        name($0) + " " + (frame($0).map { NSStringFromRect($0) } ?? "")
      }
    guard candidates.count == 1, let row = candidates.first else {
      throw WindowGroupError.unavailable(
        "Claude's conversation row is unavailable. Open its sidebar and try again.")
    }
    AXUIElementPerformAction(row, "AXScrollToVisible" as CFString)
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let rect = frame(row) else { throw WindowGroupError.ambiguous }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      throw WindowGroupError.unavailable(
        "Bring Claude to the front before opening its conversation window.")
    }
    lastNavigation.append("postEventsAllowed=\(CGPreflightPostEventAccess())")
    let point = CGPoint(x: rect.midX, y: rect.midY)
    CGEvent(
      mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
      mouseButton: .left)?.post(tap: .cghidEventTap)
    try await Task.sleep(nanoseconds: 100_000_000)
    for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
      let click = CGEvent(
        mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)
      click?.flags = .maskCommand
      click?.post(tap: .cghidEventTap)
    }
    try await Task.sleep(nanoseconds: 350_000_000)
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
