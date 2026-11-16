import AXWidgetCore
import AXWidgetUI
import AppKit
import Foundation

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let store = AppStore(demo: CommandLine.arguments.contains("--demo"))
  private var floating: FloatingController!
  private var statusItem: NSStatusItem!

  func applicationDidFinishLaunching(_ notification: Notification) {
    floating = FloatingController(store: store)
    floating.openConversation = { [weak self] conversation in self?.open(conversation) }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "circle.circle", accessibilityDescription: "AX Widget")
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
    store.start()
    if CommandLine.arguments.contains("--expanded") { floating.expand() }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let visible = UserDefaults.standard.object(forKey: "showFloating") as? Bool != false
    let toggle = menu.addItem(
      withTitle: "Floating Widget", action: #selector(toggleFloating), keyEquivalent: "")
    toggle.state = visible ? .on : .off
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
    let widgets = menu.addItem(
      withTitle: "Add Usage Widget…", action: #selector(showWidgetHelp),
      keyEquivalent: "")
    widgets.target = self
    let refresh = menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
    refresh.target = self
    menu.addItem(.separator())
    let quit = menu.addItem(
      withTitle: "Quit AX Widget", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
  }

  @objc private func toggleFloating() {
    let value = !(UserDefaults.standard.object(forKey: "showFloating") as? Bool != false)
    UserDefaults.standard.set(value, forKey: "showFloating")
    floating.setVisible(value)
  }
  @objc private func setAppearance(_ sender: NSMenuItem) {
    if let raw = sender.representedObject as? String, let appearance = Appearance(rawValue: raw) {
      store.appearance = appearance
    }
  }
  @objc private func refresh() { store.refresh(forceUsage: true) }
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
    let bundle =
      conversation.provider == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop"
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
      let alert = NSAlert()
      alert.messageText = "\(conversation.provider.label) is not installed"
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
    for url in urls {
      guard url.scheme == "ax-widget" else { continue }
      if url.host == "show" {
        floating?.expand()
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
