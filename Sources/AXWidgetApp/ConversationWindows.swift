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
    let windows = WindowAX.windows(pid)
    if let reference = bookmarks[pin.id]?.reference, let app = runningApp(pin.provider),
      reference.belongs(to: app)
    {
      guard let frame = GroupWindowInventory.read()?.entry(for: reference)?.frame else { return nil }
      let exact = windows.filter { Bookmark(frame).matches(WindowAX.frame($0)) }
      guard exact.count == 1 else { return nil }
      return existing(pin, among: exact)
    }
    return existing(pin, among: windows)
  }

  private func existing(_ pin: ConversationPin, among windows: [AXUIElement]) -> AXUIElement? {
    let matching = windows.filter {
      pin.provider == .claude ? WindowAX.isClaudePopout($0, pin: pin) : WindowAX.matches($0, pin: pin)
    }
    if matching.count == 1 { return matching.first }
    let recorded = matching.filter { bookmarks[pin.id]?.matches(WindowAX.frame($0)) == true }
    return recorded.count == 1 ? recorded.first : nil
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
        }
        continue
      }
      let bookmark = bookmarks[pin.id]
      let reference = bookmark?.reference
      let sameProcess = reference?.belongs(to: app) == true
      guard let windows = lists[pid] ?? WindowAX.windowList(pid) else { continue }
      lists[pid] = windows
      var candidates = windows
      if sameProcess, let reference {
        guard let inventory else { continue }
        // Check the recorded native number before considering any same-title copy.
        guard let entry = inventory.entry(for: reference) else {
          missing.insert(pin.id)
          continue
        }
        guard let frame = entry.frame else { continue }
        candidates = windows.filter { Bookmark(frame).matches(WindowAX.frame($0)) }
        guard candidates.count == 1 else { continue }
      }
      if let window = existing(pin, among: candidates) {
        let binding = Binding(pin: pin, pid: pid, window: window)
        if sameProcess { binding.reference = reference }
        bind(binding)
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
      if name == title {
        // A Claude main window can display the same chat after its dedicated pop-out is closed.
        return pin.provider == .claude && pin.desktopSessionID.map {
          WindowAX.isClaudeMain(window, session: $0)
        } == true
      }
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
      } else {
        let matches = WindowAX.windows(app.processIdentifier).filter {
          WindowAX.matches($0, pin: pin)
            && (pin.provider != .claude || WindowAX.isClaudePopout($0, pin: pin))
        }
        if matches.count > 1 { throw WindowGroupError.ambiguous }
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
        let (binding, created, source) = try await locateOrOpen(
          pin, alreadyGrouped: windows,
          joining: joining?.id == pin.id)
        if joining?.id == pin.id, let source,
          !originalViews.contains(where: { CFEqual($0, source) })
        {
          originalViews.append(source)
        }
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
      for source in originalViews where !windows.contains(where: { CFEqual(source, $0.window) }) {
        guard valid(replacement), WindowAX.isRegularView(source, of: joining) else { continue }
        do { try await WindowAX.closeRegularView(source, of: joining) } catch {
          duplicateCloseIssue = .unavailable(
            "The split is ready. The original \(joining.provider.label) view is still open and needs to be closed manually."
          )
        }
      }
      if !originalViews.isEmpty { try await raiseTogether(windows) }
    }
  }

  private func bound(_ pin: ConversationPin) throws -> Binding {
    if let binding = bindings[pin.id] {
      guard valid(binding) else { throw WindowGroupError.changed }
      return binding
    }
    guard let app = runningApp(pin.provider), let window = existing(pin, pid: app.processIdentifier)
    else { throw WindowGroupError.changed }
    let binding = Binding(pin: pin, pid: app.processIdentifier, window: window)
    bind(binding)
    return binding
  }

  private func raiseTogether(_ windows: [Binding]) async throws {
    // Activate once so ordinary windows from another provider stay behind the split.
    if let last = windows.last {
      NSRunningApplication(processIdentifier: last.pid)?.activate(options: [])
      AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(last.pid),
        kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    for binding in windows { try await raise(binding) }
  }

  func raiseExistingGroup(_ pins: [ConversationPin]) async throws {
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    var windows: [Binding] = []
    for pin in pins {
      if let binding = bindings[pin.id], runningApp(pin.provider)?.processIdentifier == binding.pid,
        !isClosed(binding)
      {
        windows.append(binding)
      } else {
        windows.append(try bound(pin))
      }
    }
    try await raiseTogether(windows)
  }

  func openOutsideGroup(_ pin: ConversationPin, protecting pins: [ConversationPin]) async throws {
    guard !busy else { throw WindowGroupError.changed }
    guard let url = pin.conversation.deepLink else { throw WindowGroupError.unregistered }
    busy = true
    defer { busy = false }
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    // Launch first: a cold provider may restore saved split windows. Never
    // send it a global Codex URL while that restoration is in progress.
    let app = try await providerApp(pin.provider)
    let protected = pins.compactMap { try? bound($0) }
    let pid = app.processIdentifier
    if protected.count == pins.count,
      let target = WindowAX.windows(pid).first(where: { window in
        !protected.contains { CFEqual($0.window, window) }
          && WindowAX.isRegularView(window, of: pin)
      })
    {
      try await WindowAX.focus(target, pid: pid)
      return
    }
    if pin.provider == .codex {
      _ = try await openCodexWindow(pin, app: app, useChatSearch: true)
    } else {
      // Claude's OS continuation links open its main Code view. Split windows
      // are separate native pop-outs; verify the destination by Desktop session ID.
      _ = try await openLink(url, provider: .claude)
      guard
        try await waitForNativeTransition(
          timeout: 12,
          {
            WindowAX.windows(pid).contains { window in
              !protected.contains { CFEqual($0.window, window) }
                && WindowAX.isRegularView(window, of: pin)
            }
          })
      else { throw WindowGroupError.changed }
    }
    guard protected.allSatisfy(valid) else { throw WindowGroupError.changed }
  }

  func minimize(_ pins: [ConversationPin]) throws {
    guard !busy else { return }
    guard AXIsProcessTrusted() else { throw WindowGroupError.accessibility }
    let windows = try pins.map { pin -> Binding in
      if bindings[pin.id] == nil,
        let app = runningApp(pin.provider)
      {
        if let window = existing(pin, pid: app.processIdentifier) {
          bind(Binding(pin: pin, pid: app.processIdentifier, window: window))
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
    guard try await waitForNativeTransition({ valid(binding) }) else {
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

  private func openCodexWindow(
    _ pin: ConversationPin, app: NSRunningApplication, useChatSearch: Bool
  ) async throws -> Binding {
    guard let title = CodexWindowIdentity.title(sessionID: pin.sessionID) else {
      throw WindowGroupError.unavailable(
        "Give this Codex chat a distinct title so its window can be identified.")
    }
    let pid = app.processIdentifier
    guard let before = WindowAX.windowList(pid) else { throw WindowGroupError.changed }
    try WindowAX.newCodexWindow(pid)
    var destination: AXUIElement?
    guard
      try await waitForNativeTransition(
        timeout: 10,
        {
          let added = WindowAX.windows(pid).filter { window in
            WindowAX.isStandardWindow(window) && !before.contains { CFEqual($0, window) }
          }
          destination = added.count == 1 ? added[0] : nil
          return destination != nil
        }), let destination
    else { throw WindowGroupError.unavailable("Codex could not create a separate window.") }

    try await WindowAX.focus(destination, pid: pid)
    if !useChatSearch {
      guard let url = pin.conversation.deepLink else { throw WindowGroupError.unregistered }
      _ = try await openLink(url, provider: .codex)
    } else {
      // Ordinary Codex URLs navigate the last active window. Select a chat
      // inside this specific window even if the user refocuses a split pane.
      try await WindowAX.selectCodexChat(pin, title: title, in: destination, pid: pid)
    }
    guard
      try await waitForNativeTransition(timeout: 10, { WindowAX.matches(destination, pin: pin) })
    else {
      throw WindowGroupError.unavailable(
        "Codex did not show the requested chat in the separate window.")
    }
    return Binding(pin: pin, pid: pid, window: destination)
  }

  private func locateOrOpen(
    _ pin: ConversationPin, alreadyGrouped: [Binding], joining: Bool
  ) async throws -> (Binding, Bool, AXUIElement?) {
    if let running = runningApp(pin.provider) {
      let pid = running.processIdentifier
      if let window = existing(pin, pid: pid) {
        return (Binding(pin: pin, pid: pid, window: window), false, nil)
      }
      let matches = WindowAX.windows(pid).filter { window in
        !alreadyGrouped.contains { CFEqual($0.window, window) }
          && (pin.provider == .claude
            ? WindowAX.isClaudePopout(window, pin: pin) : WindowAX.matches(window, pin: pin))
      }
      if matches.count > 1 {
        // Both windows really show the same registered chat. During an explicit
        // join, adopt the foremost regular window and retire its verified duplicate.
        guard joining, pin.provider == .codex, let first = matches.first else {
          throw WindowGroupError.ambiguous
        }
        return (Binding(pin: pin, pid: pid, window: first), false, nil)
      }
    }
    guard let url = pin.conversation.deepLink else { throw WindowGroupError.unregistered }
    if pin.provider == .codex {
      let app = try await providerApp(.codex)
      // A cold launch can restore the original chat before the new-window action.
      if let window = existing(pin, pid: app.processIdentifier) {
        return (Binding(pin: pin, pid: app.processIdentifier, window: window), false, nil)
      }
      let protecting = bindings.values.contains { $0.pin.provider == .codex && $0.pin.id != pin.id }
      return (try await openCodexWindow(pin, app: app, useChatSearch: protecting), true, nil)
    }
    guard let session = pin.desktopSessionID,
      ClaudeWindowIdentity.title(desktopSessionID: session) != nil
    else {
      throw WindowGroupError.unavailable(
        "Give this Claude chat a distinct title so its pop-out can be identified.")
    }
    let previous = runningApp(.claude).map { WindowAX.windows($0.processIdentifier) } ?? []
    let original = previous.first { WindowAX.isClaudeMain($0, session: session) }
    let otherMain = previous.first { WindowAX.claudeMainURL($0) != nil }
    var app = runningApp(.claude)
    var source = original
    // A command-click on a sidebar row opens the pop-out without navigating the
    // regular window away from its current chat.
    if source == nil, let otherMain, let app {
      do {
        try await WindowAX.openInNewWindow(pid: app.processIdentifier, window: otherMain, pin: pin)
        let window = try await waitForPopout(pin, pid: app.processIdentifier, excluding: previous)
        return (Binding(pin: pin, pid: app.processIdentifier, window: window), true, nil)
      } catch WindowGroupError.claudeRowUnavailable {
        // A collapsed project may not expose this row until it is selected.
      }
    }
    let previousSession = otherMain.flatMap { WindowAX.claudeMainURL($0) }?.lastPathComponent
    var restoreURL: URL?
    if original == nil, let previousSession, previousSession != session {
      var prior = pin
      prior.desktopSessionID = previousSession
      restoreURL = prior.conversation.deepLink
    }
    if source == nil {
      let opened = try await openLink(url, provider: .claude)
      app = opened
      let pid = opened.processIdentifier
      guard
        try await waitForNativeTransition(
          timeout: 15,
          {
            source = WindowAX.windows(pid).first { WindowAX.isClaudeMain($0, session: session) }
            return source != nil
          })
      else { throw WindowGroupError.ambiguous }
    }
    guard let app, let source else { throw WindowGroupError.changed }
    let borrowedMain = restoreURL != nil && otherMain.map { CFEqual(source, $0) } == true
    func restorePrevious() async {
      if borrowedMain, let restoreURL, let previousSession,
        WindowAX.isClaudeMain(source, session: session)
      {
        _ = try? await openLink(restoreURL, provider: .claude)
        _ = try? await waitForNativeTransition { WindowAX.isClaudeMain(source, session: previousSession) }
      }
    }
    do {
      let before = WindowAX.windows(app.processIdentifier)
      try await WindowAX.openInNewWindow(pid: app.processIdentifier, window: source, pin: pin)
      let window = try await waitForPopout(pin, pid: app.processIdentifier, excluding: before)
      await restorePrevious()
      return (
        Binding(pin: pin, pid: app.processIdentifier, window: window), true,
        borrowedMain ? nil : source
      )
    } catch {
      await restorePrevious()
      throw error
    }
  }

  private func waitForPopout(_ pin: ConversationPin, pid: pid_t, excluding old: [AXUIElement])
    async throws -> AXUIElement
  {
    var found: AXUIElement?
    guard
      try await waitForNativeTransition(
        timeout: 10,
        {
          let matches = WindowAX.windows(pid).filter { window in
            !old.contains { CFEqual($0, window) } && WindowAX.isClaudePopout(window, pin: pin)
          }
          found = matches.count == 1 ? matches[0] : nil
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
    guard value(window, kAXRoleAttribute) as? String == kAXWindowRole else { return false }
    if pin.provider == .codex {
      guard let title = CodexWindowIdentity.title(sessionID: pin.sessionID) else { return false }
      return name(window) == title
    }
    guard let session = pin.desktopSessionID else { return false }
    return isClaudePopout(window, pin: pin) || isClaudeMain(window, session: session)
  }

  static func isClaudeMain(_ window: AXUIElement, session: String) -> Bool {
    claudeMainURL(window)?.pathComponents.contains(session) == true
  }

  static func claudeMainURL(_ window: AXUIElement) -> URL? {
    var pending: [(AXUIElement, Int)] = [(window, 0)]
    var cursor = 0
    let deadline = Date().addingTimeInterval(1)
    while cursor < pending.count, cursor < 500, Date() < deadline {
      let (node, depth) = pending[cursor]
      cursor += 1
      if value(node, kAXRoleAttribute) as? String == "AXWebArea",
        let raw = value(node, "AXURL"), let url = URL(string: String(describing: raw)),
        url.scheme == "https", url.host == "claude.ai",
        url.pathComponents.contains("epitaxy") || url.pathComponents.contains("code")
      {
        // The outer native conversation document is authoritative, not links or artifact content.
        return url
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
      name(document) == title, isStandardWindow(window), claudeMainURL(window) == nil
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
