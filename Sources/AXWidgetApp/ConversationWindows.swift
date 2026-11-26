import AXWidgetCore
import AppKit
import ApplicationServices

/// Uses public macOS Accessibility window actions. Never changes a provider's window level.
@MainActor final class ConversationWindows {
  private final class Binding {
    var pin: ConversationPin
    let pid: pid_t
    let window: AXUIElement
    var watch: GroupWindowWatch?
    var reference: GroupWindowReference?

    init(pin: ConversationPin, pid: pid_t, window: AXUIElement) {
      self.pin = pin
      self.pid = pid
      self.window = window
    }
  }
  private var bindings: [String: Binding] = [:]
  // Keep the destination of an interrupted File → New Window / chat selection.
  // Retrying one request must not allocate a succession of empty windows.
  private var unfinishedCodex: [String: (window: AXUIElement, title: String)] = [:]
  private var busy = false
  private struct Bookmark: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var reference: GroupWindowReference?
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
  private let runningApp: (Provider) -> NSRunningApplication?
  private var absence = WindowAbsenceConfirmation()
  private var needsLayout = false
  private(set) var duplicateCloseIssue: WindowGroupError?
  private var lastReflowMembers: [String]?
  var onWindowClosed: (() -> Void)?

  init(persist: Bool = true, runningApp: @escaping (Provider) -> NSRunningApplication? = {
    NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).first
  }) {
    self.persist = persist
    self.runningApp = runningApp
    if persist, let data = UserDefaults.standard.data(forKey: "conversationWindowFrames") {
      bookmarks = (try? JSONDecoder().decode([String: Bookmark].self, from: data)) ?? [:]
    }
  }
  func remember() {
    lazy var inventory = GroupWindowInventory.read()
    for (id, binding) in bindings where binding.watch?.destroyed != true {
      guard let frame = WindowAX.frame(binding.window) else { continue }
      if binding.reference == nil, let app = runningApp(binding.pin.provider),
        app.processIdentifier == binding.pid, !app.isHidden,
        WindowAX.value(binding.window, kAXMinimizedAttribute) as? Bool == false
      {
        binding.reference = inventory?.reference(for: frame, app: app)
      }
      var bookmark = Bookmark(frame)
      bookmark.reference = binding.reference
      bookmarks[id] = bookmark
    }
    if persist, let data = try? JSONEncoder().encode(bookmarks) {
      UserDefaults.standard.set(data, forKey: "conversationWindowFrames")
    }
  }
  private func existing(_ pin: ConversationPin, pid: pid_t) -> AXUIElement? {
    guard let windows = WindowAX.windowList(pid) else { return nil }
    return existing(pin, among: windows)
  }

  private func existing(_ pin: ConversationPin, among windows: [AXUIElement]) -> AXUIElement? {
    // Window numbers and frames describe containers. A user can open a different
    // chat in the same container, or maximize two windows to identical frames.
    lazy var codexTitle = CodexWindowIdentity.title(sessionID: pin.sessionID)
    let matching = windows.filter { window in
      if pin.provider == .codex {
        return codexTitle.map { WindowAX.codexWindow(window, hasTitle: $0) } ?? false
      }
      return WindowAX.matches(window, pin: pin)
    }
    guard matching.count > 1 else { return matching.first }
    if let bound = bindings[pin.id],
      let retained = matching.first(where: { CFEqual($0, bound.window) }) { return retained }
    if let bookmark = bookmarks[pin.id] {
      let recorded = matching.filter { bookmark.matches(WindowAX.frame($0)) }
      if recorded.count == 1 { return recorded.first }
    }
    return matching.first
  }

  private func bind(_ binding: Binding) {
    // A temporarily unresponsive provider must return control to the widget promptly.
    AXUIElementSetMessagingTimeout(binding.window, 0.3)
    if let onWindowClosed {
      binding.watch = GroupWindowWatch(
        window: binding.window, pid: binding.pid, didClose: onWindowClosed)
    }
    bindings[binding.pin.id] = binding
  }

  /// Reattach to existing windows on startup. Never open, restore or raise anything here.
  func closedWindowIDs(in pins: [ConversationPin], now: Date = Date()) -> Set<String> {
    guard !busy, !pins.isEmpty, AXIsProcessTrusted() else {
      absence = WindowAbsenceConfirmation()
      return []
    }
    let ids = Set(pins.map(\.id))
    // Claude can rotate the CLI session ID while the exact Desktop window stays open.
    for pin in pins where bindings[pin.id] == nil && pin.provider == .claude {
      if let desktop = pin.desktopSessionID, let old = bindings.first(where: {
        !ids.contains($0.key) && $0.value.pin.desktopSessionID == desktop
      }) {
        old.value.pin = pin
        bindings[pin.id] = bindings.removeValue(forKey: old.key)
        bookmarks[pin.id] = bookmarks.removeValue(forKey: old.key)
      }
    }
    bindings = bindings.filter { ids.contains($0.key) }
    lazy var inventory = GroupWindowInventory.read()
    var lists: [pid_t: [AXUIElement]] = [:]
    var missing: Set<String> = []
    var closed: Set<String> = []
    var attached = false
    for pin in pins {
      guard let app = runningApp(pin.provider), !app.isTerminated else { continue }
      let pid = app.processIdentifier
      if let binding = bindings[pin.id], binding.pid == pid,
        binding.reference?.belongs(to: app) != false
      {
        if isClosed(binding) {
          closed.insert(pin.id)
        } else if let reference = binding.reference, let inventory,
          inventory.entry(for: reference) == nil, let windows = lists[pid] ?? WindowAX.windowList(pid)
        {
          // Some providers retain a stale AX object without sending its destroy event.
          lists[pid] = windows
          if !windows.contains(where: { CFEqual($0, binding.window) }) { missing.insert(pin.id) }
        } else if !app.isHidden, !valid(binding),
          let windows = lists[pid] ?? WindowAX.windowList(pid)
        {
          lists[pid] = windows
          if let target = existing(pin, among: windows), !CFEqual(target, binding.window) {
            bind(Binding(pin: pin, pid: pid, window: target))
            attached = true
          }
        }
        continue
      }
      let bookmark = bookmarks[pin.id]
      let reference = bookmark?.reference
      let sameProcess = reference?.belongs(to: app) == true
      guard let windows = lists[pid] ?? WindowAX.windowList(pid) else { continue }
      lists[pid] = windows
      if sameProcess, let reference {
        guard let inventory else { continue }
        // Check the recorded native number before considering any same-title copy.
        guard inventory.entry(for: reference) != nil else {
          missing.insert(pin.id)
          continue
        }
      }
      if let window = existing(pin, among: windows) {
        // Derive the number from this window. The old number may now show a different chat.
        bind(Binding(pin: pin, pid: pid, window: window))
        attached = true
      } else if reference == nil, let bookmark, !app.isHidden, app.isFinishedLaunching,
        let launch = GroupWindowReference.processStart(of: app), now.timeIntervalSince(launch) > 5,
        legacyWindowIsAbsent(pin, bookmark: bookmark, windows: windows)
      {
        missing.insert(pin.id)
      }
    }
    if attached { remember() }
    return closed.union(absence.confirm(missing, at: now))
  }

  private func isClosed(_ binding: Binding) -> Bool {
    guard let app = runningApp(binding.pin.provider), !app.isTerminated,
      app.processIdentifier == binding.pid else { return false }
    if binding.watch?.destroyed == true { return true }
    var role: CFTypeRef?
    return AXUIElementCopyAttributeValue(binding.window, kAXRoleAttribute as CFString, &role)
      == .invalidUIElement
  }

  private func legacyWindowIsAbsent(
    _ pin: ConversationPin, bookmark: Bookmark, windows: [AXUIElement]
  ) -> Bool {
    let title = pin.provider == .codex ? CodexWindowIdentity.title(sessionID: pin.sessionID)
      : pin.desktopSessionID.flatMap { ClaudeWindowIdentity.title(desktopSessionID: $0) }
    guard let title else { return false }
    return windows.allSatisfy { window in
      guard let name = WindowAX.value(window, kAXTitleAttribute) as? String, !name.isEmpty,
        WindowAX.value(window, kAXMinimizedAttribute) as? Bool == false else { return false }
      if name == title { return false }
      return !bookmark.matches(WindowAX.frame(window))
    }
  }

  /// Reflow surviving native windows on their display, without navigating or changing focus.
  func arrangeAfterClose(_ pins: [ConversationPin]) async throws {
    guard !busy, !pins.isEmpty, AXIsProcessTrusted(), let primary = NSScreen.screens.first else { return }
    let windows = visibleBindings(pins)
    lastReflowMembers = windows.map { $0.pin.id }
    guard let first = windows.first, let frame = WindowAX.frame(first.window) else { return }
    let visible = try ConversationWindowLayout.maximizedFrame(for: frame, visibleFrames: NSScreen.screens.map {
      ConversationWindowLayout.accessibilityRect($0.visibleFrame, primaryTop: primary.frame.maxY)
    })
    busy = true
    defer { busy = false }
    try await tile(windows, visible: visible, padding: windows.count == 1 ? 0 : 6)
    needsLayout = windows.count != pins.count
    remember()
  }

  func hasDeferredReflow(_ pins: [ConversationPin]) -> Bool {
    guard needsLayout, AXIsProcessTrusted() else { return false }
    let ready = visibleBindings(pins).map { $0.pin.id }
    return !ready.isEmpty && ready != lastReflowMembers
  }

  private func visibleBindings(_ pins: [ConversationPin]) -> [Binding] {
    pins.compactMap { bindings[$0.id] }.filter {
      runningApp($0.pin.provider)?.isHidden == false && valid($0)
        && WindowAX.value($0.window, kAXMinimizedAttribute) as? Bool == false
        && WindowAX.value($0.window, "AXFullScreen") as? Bool != true
    }
  }

  /// Explicit developer acceptance check; never runs during background refresh.
  /// Restores pre-existing window frames and minimizes states, and closes only pop-outs it creates.
  func verify(_ pins: [ConversationPin]) async throws -> [String: Any] {
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    let previous = NSWorkspace.shared.frontmostApplication
    let previousFocus = previous.flatMap {
      WindowAX.value(AXUIElementCreateApplication($0.processIdentifier), kAXFocusedWindowAttribute)
    }
    let originals = Provider.allCases.compactMap(runningApp).flatMap { app in
      WindowAX.windows(app.processIdentifier).map {
        ($0, WindowAX.frame($0), WindowAX.value($0, kAXMinimizedAttribute) as? Bool ?? false)
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
        if let frame, WindowAX.frame(window) != frame { try? WindowAX.setFrame(window, frame) }
        if WindowAX.value(window, kAXMinimizedAttribute) as? Bool != minimized {
          AXUIElementSetAttributeValue(
            window, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
        }
      }
      previous?.activate(options: [])
      if let previousFocus { AXUIElementPerformAction(previousFocus as! AXUIElement, kAXRaiseAction as CFString) }
    }
    let originalTargets: [(ConversationPin, AXUIElement)] = pins.compactMap { pin in
      guard let app = runningApp(pin.provider), let target = existing(pin, pid: app.processIdentifier)
      else { return nil }
      return (pin, target)
    }
    var staleBindingsTested = 0
    for (pin, target) in originalTargets {
      guard let app = runningApp(pin.provider) else { throw WindowGroupError.changed }
      let opened = try await openConversation(pin, protecting: [])
      guard CFEqual(opened, target) else { throw WindowGroupError.changed }
      if let other = WindowAX.windows(app.processIdentifier).first(where: {
        WindowAX.isStandardWindow($0) && !WindowAX.matches($0, pin: pin)
      }), let otherFrame = WindowAX.frame(other) {
        // A stale native window number and a stale live binding must both recover.
        var stale = Bookmark(otherFrame)
        stale.reference = GroupWindowInventory.read()?.reference(for: otherFrame, app: app)
        bookmarks[pin.id] = stale
        let wrong = Binding(pin: pin, pid: app.processIdentifier, window: other)
        bind(wrong)
        try await raiseExistingGroup([pin])
        guard let rebound = bindings[pin.id], CFEqual(rebound.window, target)
        else { throw WindowGroupError.changed }
        staleBindingsTested += 1
      }
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
    var repeatedReuse = true
    for (pin, original) in originalTargets {
      let others = pins.filter { $0.provider == pin.provider && $0.id != pin.id }
      let reopened = try await openConversation(pin, protecting: others)
      repeatedReuse = repeatedReuse && CFEqual(reopened, original)
        && windows.contains { $0.pin.id == pin.id && CFEqual($0.window, original) }
    }
    let inventoryPreserved = Provider.allCases.allSatisfy { provider in
      guard let app = runningApp(provider), let list = WindowAX.windowList(app.processIdentifier)
      else { return !originalTargets.contains { $0.0.provider == provider } }
      var expected = originals.filter { item in
        var pid: pid_t = 0
        return AXUIElementGetPid(item.0, &pid) == .success && pid == app.processIdentifier
      }.map(\.0)
      for binding in windows where binding.pid == app.processIdentifier
        && !expected.contains(where: { CFEqual($0, binding.window) }) { expected.append(binding.window) }
      return list.count == expected.count && expected.allSatisfy { original in
        list.contains { CFEqual($0, original) }
      }
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
    var reusedMinimized = false
    if minimized, let first = windows.first {
      let restored = try await openConversation(first.pin, protecting: [])
      reusedMinimized = CFEqual(first.window, restored)
        && WindowAX.value(restored, kAXMinimizedAttribute) as? Bool == false
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
    let restarted = ConversationWindows(persist: false, runningApp: runningApp)
    restarted.bookmarks = bookmarks
    try await restarted.show(pins, screen: NSScreen.main)
    let reused = pins.allSatisfy { pin in
      guard let old = bindings[pin.id], let new = restarted.bindings[pin.id] else { return false }
      return CFEqual(old.window, new.window)
    }
    let providerForeground = try await waitForNativeTransition {
      pins.contains {
        runningApp($0.provider)?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
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
      "alreadyOpenTargets": originalTargets.count, "reusedForOpenAndSplit": repeatedReuse,
      "staleBindingsRecovered": staleBindingsTested, "nativeWindowInventoryPreserved": inventoryPreserved,
      "reusedMinimizedWindow": reusedMinimized,
      "reusedAfterWidgetRestart": reused,
      "raisedTogether": stacking.raised.map { $0 as Any } ?? NSNull(),
      "normalWindowLevels": stacking.normal.map { $0 as Any } ?? NSNull(),
    ]
  }

  private func waitForNativeTransition(timeout: TimeInterval = 3, _ condition: () -> Bool)
    async throws -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if condition() { return true }
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    return condition()
  }

  /// Expand only the registered group window. Closing it before removal must
  /// not create a new window or resize an unrelated provider window.
  func maximizeIfPresent(_ pin: ConversationPin) async throws {
    guard !busy else { return }
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    if let registered = bindings[pin.id], isClosed(registered) { return }
    var binding = bindings[pin.id].flatMap { valid($0) ? $0 : nil }
    if binding == nil,
      let app = runningApp(pin.provider)
    {
      if let window = existing(pin, pid: app.processIdentifier) {
        binding = Binding(pin: pin, pid: app.processIdentifier, window: window)
      }
    }
    guard let binding else { return }
    guard let original = WindowAX.frame(binding.window), let primary = NSScreen.screens.first
    else { throw WindowGroupError.cannotFit }
    let target = try ConversationWindowLayout.maximizedFrame(
      for: original,
      visibleFrames: NSScreen.screens.map {
        ConversationWindowLayout.accessibilityRect($0.visibleFrame, primaryTop: primary.frame.maxY)
      })
    let wasMinimized = WindowAX.value(binding.window, kAXMinimizedAttribute) as? Bool ?? false
    busy = true
    defer { busy = false }
    do {
      try await raise(binding)
      NSRunningApplication(processIdentifier: binding.pid)?.activate(options: [])
      AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(binding.pid),
        kAXFrontmostAttribute as CFString, kCFBooleanTrue)
      let deadline = Date().addingTimeInterval(3)
      repeat {
        guard valid(binding) else { throw WindowGroupError.changed }
        try WindowAX.setFrame(binding.window, target)
        try await Task.sleep(nanoseconds: 100_000_000)
        if Bookmark(target).matches(WindowAX.frame(binding.window)) {
          if bindings[pin.id] !== binding { bind(binding) }
          remember()
          return
        }
      } while Date() < deadline
      throw WindowGroupError.unavailable(
        "The removed window could not be expanded to the display's usable area.")
    } catch {
      try? WindowAX.setFrame(binding.window, original)
      AXUIElementSetAttributeValue(
        binding.window, kAXMinimizedAttribute as CFString,
        wasMinimized ? kCFBooleanTrue : kCFBooleanFalse)
      throw error
    }
  }

  func forget(_ id: String) { forget([id]) }

  func forget(_ ids: Set<String>, arrangeRemaining: Bool = false) {
    needsLayout = arrangeRemaining
    lastReflowMembers = nil
    for id in ids {
      bindings.removeValue(forKey: id)
      bookmarks.removeValue(forKey: id)
      absence.forget(id)
    }
    remember()
  }

  func show(
    _ pins: [ConversationPin], screen: NSScreen?, arrange: Bool = false,
    joining: ConversationPin? = nil
  ) async throws {
    guard !busy, !pins.isEmpty else { return }
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    busy = true
    defer { busy = false }
    duplicateCloseIssue = nil
    var windows: [Binding] = []
    var opened = false
    var originalViews: [AXUIElement] = []
    if let joining, let app = runningApp(joining.provider) {
      originalViews = WindowAX.windows(app.processIdentifier).filter {
        WindowAX.isRegularView($0, of: joining)
      }
    }
    for pin in pins {
      if absence.isPending(pin.id) || bindings[pin.id].map(isClosed) == true {
        onWindowClosed?()
        throw WindowGroupError.unavailable("A grouped window is closing.")
      }
      if let binding = bindings[pin.id], valid(binding) {
        windows.append(binding)
      } else {
        bindings.removeValue(forKey: pin.id)
        let others = pins.filter { $0.id != pin.id && $0.provider == pin.provider }
        let (binding, created) = try await locateOrOpen(pin, protecting: others)
        bind(binding)
        windows.append(binding)
        opened = opened || created
      }
    }
    try await raiseTogether(windows)
    if arrange || opened || needsLayout {
      for binding in windows {
        await WindowAX.hideSidebar(binding.window, pid: binding.pid, provider: binding.pin.provider)
      }
      guard let target = screen ?? NSScreen.main, let primary = NSScreen.screens.first
      else { throw WindowGroupError.cannotFit }
      try await tile(windows, visible: ConversationWindowLayout.accessibilityRect(
        target.visibleFrame, primaryTop: primary.frame.maxY), padding: needsLayout && windows.count == 1 ? 0 : 6)
      needsLayout = false
      for binding in windows { try await raise(binding) }
    }
    remember()
    // Retire the exact source view only after the replacement has been verified
    // and tiled. Raising, restoring or reflowing an existing group never closes views.
    if let joining, let replacement = windows.first(where: { $0.pin.id == joining.id }) {
      let duplicates = originalViews.filter { source in !windows.contains { CFEqual(source, $0.window) } }
      for source in duplicates {
        guard valid(replacement), WindowAX.isRegularView(source, of: joining) else { continue }
        do { try await WindowAX.closeRegularView(source, of: joining) } catch {
          duplicateCloseIssue = .unavailable(
            "The split is ready. The original \(joining.provider.label) view is still open and needs to be closed manually."
          )
        }
      }
      if !duplicates.isEmpty { try await raiseTogether(windows) }
    }
  }

  private func bound(_ pin: ConversationPin) throws -> Binding {
    if let binding = bindings[pin.id], valid(binding) { return binding }
    guard let app = runningApp(pin.provider), let window = existing(pin, pid: app.processIdentifier)
    else { throw WindowGroupError.changed }
    let binding = Binding(pin: pin, pid: app.processIdentifier, window: window)
    bind(binding)
    return binding
  }

  private func raiseTogether(_ windows: [Binding]) async throws {
    // Activate once so ordinary windows from another provider stay behind the split.
    for binding in windows {
      if let app = runningApp(binding.pin.provider), app.isHidden { app.unhide() }
    }
    if let last = windows.last {
      NSRunningApplication(processIdentifier: last.pid)?.activate(options: [])
      AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(last.pid),
        kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    for binding in windows { try await raise(binding) }
  }

  func raiseExistingGroup(_ pins: [ConversationPin]) async throws {
    guard !busy else { throw WindowGroupError.changed }
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    busy = true
    defer { busy = false }
    let windows = try pins.map(bound)
    try await raiseTogether(windows)
    remember()
  }

  @discardableResult
  func openConversation(_ pin: ConversationPin, protecting pins: [ConversationPin]) async throws
    -> AXUIElement
  {
    guard !busy else { throw WindowGroupError.changed }
    guard let url = pin.conversation.deepLink else { throw WindowGroupError.unregistered }
    busy = true
    defer { busy = false }
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    let app = try await providerApp(pin.provider)
    let pid = app.processIdentifier
    let inventory = try await navigationWindows(for: pin, in: app)
    if let target = existing(pin, among: inventory) {
      try await focusConversation(target, pin: pin, pid: pid)
      return target
    }
    // Uncertainty about another pane must not prevent focusing a verified target.
    // Before navigating or creating a window, account for every protected pane.
    let protected = try pins.map(bound)
    let destination: AXUIElement
    if pin.provider == .codex && !protected.isEmpty {
      destination = try await openCodexWindow(pin, app: app).window
    } else if pin.provider == .claude,
      let main = protected.first(where: { !WindowAX.isClaudePopout($0.window, pin: $0.pin) })
    {
      destination = try await openClaudePopout(pin, pid: pid, from: main.window)
    } else {
      _ = try await openLink(url, provider: pin.provider)
      var found: AXUIElement?
      guard try await waitForNativeTransition(timeout: 12, {
        found = self.existing(pin, pid: pid)
        return found != nil
      }), let found else { throw WindowGroupError.changed }
      destination = found
    }
    try await focusConversation(destination, pin: pin, pid: pid)
    guard protected.allSatisfy(valid) else { throw WindowGroupError.changed }
    return destination
  }

  private func focusConversation(_ window: AXUIElement, pin: ConversationPin, pid: pid_t) async throws {
    let minimized = WindowAX.value(window, kAXMinimizedAttribute) as? Bool == true
    do {
      try await WindowAX.focus(window, pid: pid)
      guard try await waitForNativeTransition({
        WindowAX.isStandardWindow(window) && WindowAX.matches(window, pin: pin)
      }) else { throw WindowGroupError.changed }
    } catch {
      if minimized {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
      }
      throw error
    }
  }

  func minimize(_ pins: [ConversationPin]) throws {
    guard !busy else { return }
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    let windows = try pins.map(bound)
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
    guard binding.watch?.destroyed != true, let app = runningApp(binding.pin.provider),
      !app.isTerminated, app.processIdentifier == binding.pid
    else { return false }
    return WindowAX.matches(binding.window, pin: binding.pin)
  }

  private func raise(_ binding: Binding) async throws {
    if WindowAX.value(binding.window, "AXFullScreen") as? Bool == true {
      throw WindowGroupError.unavailable(
        "Leave full screen for the pinned conversation before showing its group.")
    }
    let minimized = WindowAX.value(binding.window, kAXMinimizedAttribute) as? Bool == true
    if minimized {
      guard
        AXUIElementSetAttributeValue(
          binding.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
      else { throw WindowGroupError.unavailable("The conversation window could not be restored.") }
    }
    guard try await waitForNativeTransition({ WindowAX.isStandardWindow(binding.window) && valid(binding) }) else {
      if minimized {
        AXUIElementSetAttributeValue(
          binding.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
      }
      throw WindowGroupError.changed
    }
    // macOS can acknowledge deminiaturizing before the window accepts AXRaise.
    guard
      try await waitForNativeTransition({
        WindowAX.value(binding.window, kAXMinimizedAttribute) as? Bool == false
          && AXUIElementPerformAction(binding.window, kAXRaiseAction as CFString) == .success
      })
    else { throw WindowGroupError.unavailable("The conversation window could not be raised.") }
    AXUIElementSetAttributeValue(binding.window, kAXMainAttribute as CFString, kCFBooleanTrue)
  }

  private func tile(_ windows: [Binding], visible: CGRect, padding: CGFloat) async throws {
    let originals = try windows.map { binding -> CGRect in
      guard let frame = WindowAX.frame(binding.window) else { throw WindowGroupError.cannotFit }
      return frame
    }
    var minimums = Array(repeating: CGFloat(320), count: windows.count)
    do {
      for _ in 0...windows.count {
        let frames = try ConversationWindowLayout.frames(
          minimumWidths: minimums, visible: visible, gap: 6, padding: padding)
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

  private func openLink(_ url: URL, provider: Provider) async throws -> NSRunningApplication {
    guard
      let appURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: provider.bundleIdentifier)
    else { throw WindowGroupError.unavailable("\(provider.label) is not installed.") }
    return try await NSWorkspace.shared.open(
      [url], withApplicationAt: appURL, configuration: .init())
  }

  private func providerApp(_ provider: Provider) async throws -> NSRunningApplication {
    if let running = runningApp(provider) { return running }
    guard
      let appURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: provider.bundleIdentifier)
    else { throw WindowGroupError.unavailable("\(provider.label) is not installed.") }
    return try await NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
  }

  /// A provider can publish its AX window list before restoring its documents.
  /// A positive session match is usable immediately. Before deciding it is absent,
  /// require a readable, settled list and give a newly launched renderer time to restore.
  private func navigationWindows(for pin: ConversationPin, in app: NSRunningApplication)
    async throws -> [AXUIElement]
  {
    let pid = app.processIdentifier
    let launch = GroupWindowReference.processStart(of: app)
    let deadline = Date().addingTimeInterval(8)
    var previous: [AXUIElement]?
    repeat {
      if let list = WindowAX.windowList(pid) {
        if existing(pin, among: list) != nil { return list }
        if app.isFinishedLaunching, launch.map({ Date().timeIntervalSince($0) > 3 }) != false,
          let previous, previous.count == list.count,
          list.allSatisfy({ window in previous.contains { CFEqual(window, $0) } }),
          list.filter(WindowAX.isStandardWindow).allSatisfy({ !WindowAX.name($0).isEmpty })
        {
          if pin.provider == .codex, CodexWindowIdentity.title(sessionID: pin.sessionID) == nil {
            throw WindowGroupError.ambiguous
          }
          if pin.provider == .claude, let session = pin.desktopSessionID {
            let title = ClaudeWindowIdentity.title(desktopSessionID: session) ?? pin.title
            for window in list where WindowAX.isConversationWindow(window) {
              let name = WindowAX.name(window)
              if (name == title || (name == "Claude" &&
                WindowAX.value(window, kAXMinimizedAttribute) as? Bool == true)),
                WindowAX.claudeMainURL(window) == nil {
                throw WindowGroupError.ambiguous
              }
            }
          }
          return list
        }
        previous = list
      } else {
        previous = nil
      }
      try await Task.sleep(nanoseconds: 180_000_000)
    } while Date() < deadline && !app.isTerminated
    throw WindowGroupError.unavailable("The provider's window list is still loading. Try opening this chat again.")
  }

  private func openCodexWindow(_ pin: ConversationPin, app: NSRunningApplication) async throws -> Binding {
    guard let title = CodexWindowIdentity.title(sessionID: pin.sessionID) else {
      throw WindowGroupError.unavailable(
        "Give this Codex chat a distinct title so its window can be identified.")
    }
    let pid = app.processIdentifier
    guard let before = WindowAX.windowList(pid) else { throw WindowGroupError.changed }
    unfinishedCodex = unfinishedCodex.filter { _, item in
      before.contains { CFEqual($0, item.window) } && WindowAX.name(item.window) == item.title
    }
    if let open = existing(pin, among: before) {
      unfinishedCodex.removeValue(forKey: pin.id)
      return Binding(pin: pin, pid: pid, window: open)
    }
    let destination: AXUIElement
    if let prior = unfinishedCodex[pin.id] {
      guard WindowAX.canRetryChatSelection(in: prior.window) else {
        throw WindowGroupError.unavailable("The Codex window opened for this chat has an active input. Finish or close it before retrying.")
      }
      destination = prior.window
    } else {
      try WindowAX.newCodexWindow(pid)
      var newWindow: AXUIElement?
      guard try await waitForNativeTransition(timeout: 10, {
          let added = WindowAX.windows(pid).filter { window in
            WindowAX.isStandardWindow(window) && !before.contains { CFEqual($0, window) }
          }
          newWindow = added.count == 1 ? added[0] : nil
          return newWindow != nil
        }), let newWindow else { throw WindowGroupError.unavailable("Codex could not create a separate window.") }
      destination = newWindow
      unfinishedCodex[pin.id] = (newWindow, WindowAX.name(newWindow))
    }
    try await WindowAX.focus(destination, pid: pid)
    // Select inside the destination even for the first split pane. A global
    // link could otherwise follow the user's focus back to another open chat.
    try await WindowAX.selectCodexChat(pin, title: title, in: destination, pid: pid)
    guard
      try await waitForNativeTransition(timeout: 10, { WindowAX.matches(destination, pin: pin) })
    else {
      throw WindowGroupError.unavailable(
        "Codex did not show the requested chat in the separate window.")
    }
    unfinishedCodex.removeValue(forKey: pin.id)
    return Binding(pin: pin, pid: pid, window: destination)
  }

  private func locateOrOpen(
    _ pin: ConversationPin, protecting others: [ConversationPin]
  ) async throws -> (Binding, Bool) {
    guard let url = pin.conversation.deepLink else { throw WindowGroupError.unregistered }
    let app = try await providerApp(pin.provider)
    let pid = app.processIdentifier
    let previous = try await navigationWindows(for: pin, in: app)
    if let window = existing(pin, among: previous) {
      return (Binding(pin: pin, pid: pid, window: window), false)
    }
    if pin.provider == .codex {
      return (try await openCodexWindow(pin, app: app), true)
    }
    guard let session = pin.desktopSessionID,
      ClaudeWindowIdentity.title(desktopSessionID: session) != nil
    else {
      throw WindowGroupError.unavailable(
        "Give this Claude chat a distinct title so its pop-out can be identified.")
    }
    let otherMain = previous.first { WindowAX.claudeMainURL($0) != nil }
    if let otherMain {
      do {
        let window = try await openClaudePopout(pin, pid: pid, from: otherMain)
        return (Binding(pin: pin, pid: pid, window: window), true)
      } catch WindowGroupError.claudeRowUnavailable {
        // A collapsed project may expose its chat only after native continuation.
      }
    }
    // A global Claude link can navigate any main window. Only borrow one if
    // all other members of this provider are verified pop-outs.
    for other in others {
      let binding = try bound(other)
      if !WindowAX.isClaudePopout(binding.window, pin: other) {
        throw WindowGroupError.claudeRowUnavailable
      }
    }
    let previousSession = otherMain.flatMap { WindowAX.claudeMainURL($0) }?.lastPathComponent
    var restoreURL: URL?
    if let previousSession, previousSession != session {
      var prior = pin
      prior.desktopSessionID = previousSession
      restoreURL = prior.conversation.deepLink
    }
    _ = try await openLink(url, provider: .claude)
    var sourceWindow: AXUIElement?
    guard try await waitForNativeTransition(timeout: 15, {
      sourceWindow = self.existing(pin, pid: pid)
      return sourceWindow != nil
    }), let source = sourceWindow else { throw WindowGroupError.changed }
    guard let restoreURL, let previousSession, let otherMain, CFEqual(source, otherMain)
    else { return (Binding(pin: pin, pid: pid, window: source), true) }
    func restorePrevious() async {
      if WindowAX.isClaudeMain(source, session: session) {
        _ = try? await openLink(restoreURL, provider: .claude)
        _ = try? await waitForNativeTransition { WindowAX.isClaudeMain(source, session: previousSession) }
      }
    }
    do {
      let window = try await openClaudePopout(pin, pid: pid, from: source)
      await restorePrevious()
      return (Binding(pin: pin, pid: pid, window: window), true)
    } catch {
      await restorePrevious()
      throw error
    }
  }

  private func openClaudePopout(_ pin: ConversationPin, pid: pid_t, from source: AXUIElement)
    async throws -> AXUIElement
  {
    guard let before = WindowAX.windowList(pid) else { throw WindowGroupError.changed }
    if let existing = before.first(where: { WindowAX.isClaudePopout($0, pin: pin) }) { return existing }
    try await WindowAX.openInNewWindow(pid: pid, window: source, pin: pin)
    var found: AXUIElement?
    guard
      try await waitForNativeTransition(
        timeout: 10,
        {
          found = WindowAX.windows(pid).first { WindowAX.isClaudePopout($0, pin: pin) }
          return found != nil
        }), let found
    else {
      throw WindowGroupError.unavailable("Claude did not open a separate window for this chat.")
    }
    return found
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
      var current = hit, let ownerWindow = value(current, kAXWindowAttribute),
      CFEqual(ownerWindow as CFTypeRef, window)
    else { return }
    for _ in 0..<6 {
      var owner: pid_t = 0
      guard AXUIElementGetPid(current, &owner) == .success, owner == pid else { return }
      if value(current, kAXRoleAttribute) as? String == "AXButton" {
        let label = sidebarAction(name(current))
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
    let controls = windows.map { pid, window in
      let controls = [value(window, kAXCloseButtonAttribute), value(window, kAXMinimizeButtonAttribute),
        value(window, kAXZoomButtonAttribute) ?? value(window, "AXFullScreenButton")]
      return (pid, controls.compactMap { $0.flatMap { frame($0 as! AXUIElement) } })
    }
    let raised = indices.allSatisfy { index in
      !rows.prefix(index).enumerated().contains { other, row in
        guard row.2 == 0, !group.contains(other) else { return false }
        // Electron can give the three title-bar buttons their own layer-zero
        // WindowServer surface. That surface belongs to the raised group.
        if controls.contains(where: { $0.0 == row.0 && coversTitleBarButtons(row.1, buttons: $0.1) }) {
          return false
        }
        let overlap = row.1.intersection(rows[index].1)
        return !overlap.isNull && overlap.width * overlap.height > 100
      }
    }
    return (raised, indices.allSatisfy { rows[$0].2 == 0 })
  }

  static func coversTitleBarButtons(_ surface: CGRect, buttons: [CGRect]) -> Bool {
    guard buttons.count == 3, buttons.allSatisfy({ !$0.isEmpty && $0.width <= 24 && $0.height <= 24 }),
      let first = buttons.first else { return false }
    let cluster = buttons.dropFirst().reduce(first) { $0.union($1) }
    guard cluster.width >= 32 && cluster.width < 90 && cluster.height <= 26 else { return false }
    return cluster.insetBy(dx: -8, dy: -6).contains(surface)
      && buttons.allSatisfy { surface.contains(CGPoint(x: $0.midX, y: $0.midY)) }
  }
  static func value(_ element: AXUIElement, _ name: String) -> Any? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else {
      return nil
    }
    return result
  }
  static func windows(_ pid: pid_t) -> [AXUIElement] { windowList(pid) ?? [] }

  static func windowList(_ pid: pid_t) -> [AXUIElement]? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    // Electron documents this opt-in for native assistive clients. It exposes
    // the renderer tree without enabling VoiceOver or changing system settings.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    return value(app, kAXWindowsAttribute) as? [AXUIElement]
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
    if pin.provider == .codex {
      guard let title = CodexWindowIdentity.title(sessionID: pin.sessionID) else { return false }
      return codexWindow(window, hasTitle: title)
    }
    guard isConversationWindow(window), let session = pin.desktopSessionID else { return false }
    if let main = claudeMainURL(window) { return main.lastPathComponent == session }
    return isClaudePopout(window, pin: pin)
  }

  static func codexWindow(_ window: AXUIElement, hasTitle title: String) -> Bool {
    isConversationWindow(window) && name(window) == title
  }

  static func isClaudeMain(_ window: AXUIElement, session: String) -> Bool {
    claudeMainURL(window)?.lastPathComponent == session
  }

  static func claudeMainURL(_ window: AXUIElement) -> URL? {
    var pending: [(AXUIElement, Int)] = [(window, 0)]
    var cursor = 0
    let deadline = Date().addingTimeInterval(1)
    while cursor < pending.count, cursor < 500, Date() < deadline {
      let (node, depth) = pending[cursor]
      cursor += 1
      if value(node, kAXRoleAttribute) as? String == "AXWebArea" {
        guard let raw = value(node, "AXURL"), let url = URL(string: String(describing: raw))
        else { continue }
        if url.scheme == "https", url.host == "claude.ai",
          ["epitaxy", "code"].contains(url.pathComponents.dropFirst().first ?? "")
        { return url }
        // Only the desktop shell embeds the actual main document. Never search
        // another document's transcript, links or previews for a conversation ID.
        if !url.isFileURL || !url.path.hasSuffix("/main_window/index.html") { continue }
      }
      if depth < 24 {
        let children = value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        pending.append(
          contentsOf: children.prefix(max(0, 1000 - pending.count)).map { ($0, depth + 1) })
      }
    }
    return nil
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
    let blankDocuments = header.filter {
      value($0, kAXRoleAttribute) as? String == "AXWebArea"
        && String(describing: value($0, "AXURL") ?? "") == "about:blank"
    }
    // Current Claude gives both the native pop-out and its blank document the
    // registered session title. Its previous renderer exposed a return button.
    if blankDocuments.count == 1, let document = blankDocuments.first,
      name(document) == title, isConversationWindow(window), claudeMainURL(window) == nil
    { return true }
    let returnButton = header.contains { node in
      guard value(node, kAXRoleAttribute) as? String == "AXButton",
        name(node) == "Open in main window", let rect = frame(node)
      else { return false }
      return rect.minY < bounds.minY + 65 && rect.height <= 40
    }
    return !blankDocuments.isEmpty && returnButton
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
          var current = hit, let ownerWindow = value(current, kAXWindowAttribute),
          CFEqual(ownerWindow as CFTypeRef, window)
        {
          for _ in 0..<6 {
            var owner: pid_t = 0
            guard AXUIElementGetPid(current, &owner) == .success else { break }
            lastNavigation.append(
              "toolbarHit=\(value(current, kAXRoleAttribute) as? String ?? ""):\(name(current)) owner=\(owner)"
            )
            guard owner == pid else { break }
            if value(current, kAXRoleAttribute) as? String == "AXButton",
              let label = sidebarAction(name(current))
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
      let buttons = controls.filter {
        value($0, kAXRoleAttribute) as? String == "AXButton"
          && sidebarAction(name($0)).map(labels.contains) == true
      }
      guard buttons.count == 1 else { return false }
      return AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success
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
    guard let id = pin.desktopSessionID,
      let currentTitle = ClaudeWindowIdentity.title(desktopSessionID: id)
    else { throw WindowGroupError.ambiguous }
    // The first session can start immediately below the 36-point title bar.
    // Off-screen rows can still be scrolled into view by Accessibility.
    func sidebarRows() -> [AXUIElement] {
      navigationNodes(window, bounds: bounds).filter { node in
        guard let bounds, let rect = frame(node),
          ["AXLink", "AXRow", "AXButton"].contains(value(node, kAXRoleAttribute) as? String ?? ""),
          rect.minX >= bounds.minX, rect.minX < bounds.minX + 100,
          rect.maxX <= bounds.minX + 360, rect.width >= 100, (1..<120).contains(rect.height)
        else { return false }
        let name = name(node)
        return name == currentTitle || name.hasPrefix(currentTitle + " ")
      }
    }
    var candidates = sidebarRows()
    if shownSidebar, candidates.isEmpty {
      try await Task.sleep(nanoseconds: 250_000_000)
      candidates = sidebarRows()
    }
    lastNavigation += ["sidebarOpened=\(shownSidebar)", "matchingRows=\(candidates.count)"]
    guard candidates.count == 1, let row = candidates.first else {
      throw WindowGroupError.claudeRowUnavailable
    }
    AXUIElementPerformAction(row, "AXScrollToVisible" as CFString)
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let rect = frame(row), let bounds, rect.midY >= bounds.minY + 36,
      bounds.contains(CGPoint(x: rect.midX, y: rect.midY))
    else { throw WindowGroupError.claudeRowUnavailable }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    let point = CGPoint(x: rect.midX, y: rect.midY)
    var hit: AXUIElement?
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      let focused = value(app, kAXFocusedWindowAttribute), CFEqual(focused as CFTypeRef, window),
      CGPreflightPostEventAccess(),
      AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
      let hit, belongs(hit, to: row),
      let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else {
      throw WindowGroupError.unavailable("Claude's conversation row moved or is covered. Bring its window forward and try again.")
    }
    for click in [down, up] {
      click.flags = .maskCommand
      click.setIntegerValueField(.mouseEventClickState, value: 1)
      click.post(tap: .cghidEventTap)
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
        if provider == .codex {
          result["questionCards"] = SnapshotStore.read().conversations
            .filter { $0.provider == .codex && $0.needsAttention }.flatMap { conversation in
              let window = CodexDesktopQuestions.window(pid: app.processIdentifier, session: conversation.sessionID)
              return (conversation.questions ?? []).filter { $0.kind == .codexAsync }.flatMap { group in
                group.questions.map { question -> [String: Any] in
                  let card = window.flatMap { CodexDesktopQuestions.form(in: $0, question: question) }
                  return ["window": window != nil, "card": card != nil,
                    "sendEnabled": card.flatMap { value($0.submit, kAXEnabledAttribute) as? Bool } ?? false]
                }
              }
            }
        }
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
                "AXTextField", "AXTextArea", "AXRadioButton", "AXCheckBox",
              ].contains(role)
            else { return nil }
            return [
              "role": role, "name": name(node),
              "enabled": (value(node, kAXEnabledAttribute) as? Bool).map(String.init) ?? "",
              "selected": ["AXRadioButton", "AXCheckBox"].contains(role)
                ? (value(node, kAXValueAttribute) as? NSNumber)?.stringValue ?? "" : "",
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
