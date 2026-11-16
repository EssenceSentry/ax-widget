import AXWidgetCore
import AXWidgetUI
import AppKit
import Combine
import Foundation

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let store = AppStore(demo: CommandLine.arguments.contains("--demo"))
  private var floating: FloatingController!
  private var statusItem: NSStatusItem!
  private var pendingURLs: [URL] = []
  private var answering = false
  private var statusSubscription: AnyCancellable?
  private let conversationWindows = ConversationWindows()
  private var groupOperation = false {
    didSet { store.setGroupBusy(groupOperation) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    floating = FloatingController(store: store)
    floating.openConversation = { [weak self] conversation in self?.open(conversation) }
    floating.newConversation = { [weak self] provider in self?.startConversation(provider) }
    floating.toggleConversationPin = { [weak self] in self?.togglePin($0) }
    floating.showGroup = { [weak self] in self?.showConversationGroup() }
    floating.minimizeGroup = { [weak self] in self?.minimizeConversationGroup() }
    floating.arrangeGroup = { [weak self] in self?.showConversationGroup(arrange: true) }
    floating.answerQuestion = { [weak self] conversation, group, answers in
      guard let self else { return "AX Widget is unavailable." }
      return await self.answer(conversation, group: group, answers: answers)
    }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.title = ""
      button.image = MenuBarIcon.axe
      button.imagePosition = .imageOnly
      button.setAccessibilityLabel("ax")
      button.toolTip = "Click to toggle conversations · Right-click for options"
      button.target = self
      button.action = #selector(statusClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    floating.isTriggerClick = { [weak self] point in
      guard let button = self?.statusItem.button, let window = button.window else { return false }
      return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
    }
    statusSubscription = store.$snapshot.sink { [weak self] snapshot in
      guard let button = self?.statusItem.button else { return }
      let pending = snapshot.conversations.contains(where: \.needsAttention)
      button.setAccessibilityLabel(pending ? "ax, question waiting" : "ax")
      button.toolTip =
        pending
        ? "Question waiting · Click to answer · Right-click for options"
        : "Click to toggle conversations · Right-click for options"
    }
    store.start()
    if CommandLine.arguments.contains("--expanded") { floating.expand() }
    let urls = pendingURLs
    pendingURLs.removeAll()
    if !urls.isEmpty { application(NSApp, open: urls) }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let toggle = menu.addItem(
      withTitle: "Keep floating", action: #selector(toggleFloating), keyEquivalent: "")
    toggle.state = floating.keepFloating ? .on : .off
    toggle.target = self
    let appearance = NSMenu()
    for value in Appearance.allCases {
      let item = appearance.addItem(
        withTitle: value.label, action: #selector(setAppearance(_:)), keyEquivalent: "")
      item.representedObject = value.rawValue
      item.state = store.appearance == value ? .on : .off
      item.target = self
    }
    let entry = menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
    entry.submenu = appearance
    menu.addItem(.separator())
    if !store.group.pins.isEmpty {
      for (title, action) in [
        ("Show conversation group", #selector(showGroupMenu)),
        ("Minimize conversation group", #selector(minimizeGroupMenu)),
        ("Arrange conversations side by side", #selector(arrangeGroupMenu)),
      ] {
        menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
      }
      let pins = NSMenu()
      for pin in store.group.pins {
        let item = pins.addItem(
          withTitle: "Unpin \(pin.title)", action: #selector(unpinMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = pin.id
      }
      menu.addItem(withTitle: "Pinned conversations", action: nil, keyEquivalent: "").submenu = pins
      menu.addItem(.separator())
    }
    let widgets = menu.addItem(
      withTitle: "Add Usage Widget…", action: #selector(showWidgetHelp),
      keyEquivalent: "")
    widgets.target = self
    if !ClaudeQuestionClient.isTrusted {
      let replies = menu.addItem(
        withTitle: "Enable window control and Claude replies…",
        action: #selector(enableClaudeReplies),
        keyEquivalent: "")
      replies.target = self
    }
    let refresh = menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
    refresh.target = self
    menu.addItem(.separator())
    let quit = menu.addItem(
      withTitle: "Quit AX Widget", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
  }

  @objc private func statusClicked(_ sender: NSStatusBarButton) {
    if let event = NSApp.currentEvent,
      event.type == .rightMouseUp || event.modifierFlags.contains(.control)
    {
      let menu = NSMenu()
      menu.delegate = self
      menuNeedsUpdate(menu)
      NSMenu.popUpContextMenu(menu, with: event, for: sender)
    } else {
      floating.toggle()
    }
  }

  @objc private func toggleFloating() {
    floating.setKeepFloating(!floating.keepFloating)
  }
  @objc private func setAppearance(_ sender: NSMenuItem) {
    if let raw = sender.representedObject as? String, let appearance = Appearance(rawValue: raw) {
      store.appearance = appearance
    }
  }
  @objc private func refresh() { store.refresh(forceUsage: true) }
  @objc private func showGroupMenu() { showConversationGroup() }
  @objc private func minimizeGroupMenu() { minimizeConversationGroup() }
  @objc private func arrangeGroupMenu() { showConversationGroup(arrange: true) }
  @objc private func unpinMenu(_ item: NSMenuItem) {
    guard let id = item.representedObject as? String,
      let pin = store.group.pins.first(where: { $0.id == id })
    else { return }
    togglePin(pin.conversation)
  }

  private func togglePin(_ conversation: Conversation) {
    guard !store.demo, !groupOperation else { return }
    var group = store.group
    if group.pins.contains(where: { $0.id == conversation.id }) {
      group.remove(conversation.id)
      conversationWindows.forget(conversation.id)
      store.setGroup(group)
      store.reportGroupError(nil)
      if !group.pins.isEmpty { showConversationGroup(arrange: true) }
    } else {
      do {
        try group.add(conversation)
        groupOperation = true
        Task {
          defer { groupOperation = false }
          do {
            try await conversationWindows.show(
              group.pins, screen: floating.groupScreen,
              arrange: true, newlyPinnedID: conversation.id)
            store.setGroup(group)
            store.reportGroupError(nil)
            floating.collapse()
          } catch {
            conversationWindows.forget(conversation.id)
            store.reportGroupError(error)
            floating.expand()
            if !ClaudeQuestionClient.isTrusted { enableClaudeReplies() }
          }
        }
      } catch { store.reportGroupError(error) }
    }
  }

  private func showConversationGroup(arrange: Bool = false, newlyPinnedID: String? = nil) {
    guard !store.demo, !groupOperation else { return }
    groupOperation = true
    Task {
      defer { groupOperation = false }
      do {
        try await conversationWindows.show(
          store.group.pins, screen: floating.groupScreen,
          arrange: arrange, newlyPinnedID: newlyPinnedID)
        store.reportGroupError(nil)
        floating.collapse()
      } catch {
        store.reportGroupError(error)
        floating.expand()
        if !ClaudeQuestionClient.isTrusted { enableClaudeReplies() }
      }
    }
  }

  private func minimizeConversationGroup() {
    guard !store.demo, !groupOperation else { return }
    do {
      try conversationWindows.minimize(store.group.pins)
      store.reportGroupError(nil)
      floating.collapse()
    } catch {
      store.reportGroupError(error)
      floating.expand()
    }
  }
  @objc private func enableClaudeReplies() {
    guard !ClaudeQuestionClient.requestAccessibility(),
      let settings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(settings)
  }
  @objc private func quit() { NSApp.terminate(nil) }
  @objc private func showWidgetHelp() {
    let alert = NSAlert()
    alert.messageText = "Add AX Widget to Notification Center"
    alert.informativeText =
      "Click the date and time in the menu bar, choose Edit Widgets, and search for AX Widget. Add the small Usage widget. You can also place it on the desktop.\n\nThe widget shows a snapshot; macOS controls its refresh timing. Keep AX Widget running to publish updated data. Click it to open the floating conversation panel."
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  private func answer(
    _ conversation: Conversation, group: AgentQuestionGroup, answers: [String: [String]]
  ) async -> String? {
    guard !store.demo, !answering, let source = conversation.source,
      let fresh = try? TranscriptReader.read(URL(fileURLWithPath: source)),
      fresh.questions.contains(group), let url = conversation.deepLink
    else {
      return
        "This question has changed or is no longer awaiting an answer. Refresh or open the conversation."
    }
    if conversation.provider == .claude && !ClaudeQuestionClient.isTrusted {
      return QuestionDeliveryError.accessibilityRequired.localizedDescription
    }
    guard
      let app = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: conversation.provider.bundleIdentifier)
    else {
      return "\(conversation.provider.label) is not installed."
    }
    answering = true
    defer { answering = false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    do {
      let running: NSRunningApplication = try await withCheckedThrowingContinuation {
        continuation in
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) {
          running, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let running {
            continuation.resume(returning: running)
          } else {
            continuation.resume(throwing: AxClient.ClientError.unavailable)
          }
        }
      }
      let pid = running.processIdentifier
      try await Task.detached(priority: .userInitiated) {
        if conversation.provider == .codex {
          try CodexQuestionClient.reply(
            sessionID: conversation.sessionID, group: group, answers: answers)
        } else {
          try ClaudeQuestionClient.reply(pid: pid, group: group, answers: answers)
        }
      }.value
      return nil
    } catch { return error.localizedDescription }
  }

  private func open(_ conversation: Conversation) {
    guard !store.demo else { return }
    guard let url = conversation.deepLink else {
      let alert = NSAlert()
      alert.messageText = "Conversation unavailable in Desktop"
      alert.informativeText =
        "This Claude conversation has no native Desktop registration yet. ax registers eligible conversations while Claude Desktop is fully quit."
      alert.runModal()
      return
    }
    open(url, provider: conversation.provider)
  }

  private func startConversation(_ provider: Provider) {
    guard !store.demo else { return }
    let project =
      store.snapshot.conversations.first { $0.provider == provider && $0.project.hasPrefix("/") }?
      .project
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    guard let url = provider.newConversationURL(project: project) else { return }
    open(url, provider: provider)
  }

  private func open(_ url: URL, provider: Provider) {
    guard
      let app = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: provider.bundleIdentifier)
    else {
      let alert = NSAlert()
      alert.messageText = "\(provider.label) is not installed"
      alert.runModal()
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) {
      _, error in
      if let error {
        Task { @MainActor in
          let alert = NSAlert(error: error)
          alert.runModal()
        }
      }
    }
    floating.collapse()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard floating != nil else {
      pendingURLs.append(contentsOf: urls)
      return
    }
    for url in urls {
      guard url.scheme == "ax-widget" else { continue }
      if url.host == "show" {
        floating?.expand()
        continue
      }
      if url.host == "accessibility" {
        enableClaudeReplies()
        continue
      }
      if url.host == "group" {
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
          .first { $0.name == "action" }?.value
        if action == "minimize" {
          minimizeConversationGroup()
        } else {
          showConversationGroup(arrange: action == "arrange")
        }
        continue
      }
      let parts = url.pathComponents.filter { $0 != "/" }
      guard url.host == "conversation", parts.count == 2, UUID(uuidString: parts[1]) != nil,
        let provider = Provider(rawValue: parts[0])
      else { continue }
      let items = store.snapshot.conversations + LocalRepository().conversations(limit: 40).items
      if let conversation = items.first(where: {
        $0.provider == provider && $0.sessionID == parts[1]
      }) {
        open(conversation)
      }
    }
  }
}

@main enum Main {
  @MainActor static func main() {
    if let index = CommandLine.arguments.firstIndex(of: "--verify-window-group") {
      let ids = Array(CommandLine.arguments.dropFirst(index + 1))
      let retained = ids.compactMap { id -> ConversationPin? in
        let parts = id.split(separator: ":")
        guard parts.count == 2, parts[0] == "codex",
          let title = CodexWindowIdentity.title(sessionID: String(parts[1]))
        else { return nil }
        return ConversationPin(
          Conversation(
            provider: .codex, sessionID: String(parts[1]),
            title: title, updated: .distantPast))
      }
      let recent = LocalRepository().conversations(limit: 40, pins: retained).items
      let pins = ids.compactMap { id in recent.first { $0.id == id }.map(ConversationPin.init) }
      guard !pins.isEmpty, pins.count == ids.count, pins.count <= 3,
        Set(ids).count == ids.count
      else {
        FileHandle.standardOutput.write(
          Data("{\"error\":\"Pass one to three distinct known provider:session IDs.\"}".utf8))
        return
      }
      let app = NSApplication.shared
      app.setActivationPolicy(.accessory)
      Task {
        let client = ConversationWindows()
        var report: [String: Any]
        do { report = try await client.verify(pins) } catch {
          report = ["error": error.localizedDescription]
        }
        if let data = try? JSONSerialization.data(withJSONObject: report) {
          FileHandle.standardOutput.write(data)
        }
        app.terminate(nil)
      }
      app.run()
      return
    }
    if CommandLine.arguments.contains("--window-diagnostics") {
      let data = try? JSONSerialization.data(withJSONObject: [
        "accessibilityTrusted": ClaudeQuestionClient.isTrusted,
        "providers": WindowAX.diagnostics(),
      ])
      if let data { FileHandle.standardOutput.write(data) }
      return
    }
    if CommandLine.arguments.contains("--accessibility-status") {
      let data = try? JSONSerialization.data(withJSONObject: [
        "accessibilityTrusted": ClaudeQuestionClient.isTrusted
      ])
      if let data { FileHandle.standardOutput.write(data) }
      return
    }
    if CommandLine.arguments.contains("--dump-snapshot") {
      let result = LocalRepository().conversations()
      let usage = AxClient.executable().flatMap { try? AxClient.usage(executable: $0) } ?? []
      let snapshot = Snapshot(allowances: usage, conversations: result.items, issues: result.issues)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .secondsSince1970
      if let data = try? encoder.encode(snapshot) { FileHandle.standardOutput.write(data) }
      return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
