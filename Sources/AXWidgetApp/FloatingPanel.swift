import AXWidgetCore
import AXWidgetUI
import AppKit
import Combine
import SwiftUI

private final class UtilityPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { (delegate as? FloatingController)?.collapse() }
}

private final class CollapsedHost: NSHostingView<CollapsedView> {
  var clicked: (() -> Void)?
  var moved: (() -> Void)?
  var hasGroup = false
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    if hasGroup && convert(event.locationInWindow, from: nil).x >= 96 {
      super.mouseDown(with: event)
      return
    }
    guard let window else { return }
    while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
      if next.type == .leftMouseDragged {
        window.performDrag(with: next)
        moved?()
        return
      }
      if next.type == .leftMouseUp {
        clicked?()
        return
      }
    }
  }
}

@MainActor final class FloatingController: NSObject, NSWindowDelegate {
  let store: AppStore
  private let panel: UtilityPanel
  private let details: UtilityPanel
  private var subscription: AnyCancellable?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var presentation: FloatingPresentation
  private var expanded: Bool { presentation.isExpanded }
  var keepFloating: Bool { presentation.keepFloating }
  private var contentHeight: CGFloat = 0
  private var collapsedOrigin: NSPoint
  var openConversation: ((Conversation) -> Void)?
  var newConversation: ((Provider) -> Void)?
  var answerQuestion: QuestionAnswerHandler?
  var toggleConversationPin: ((Conversation) -> Void)?
  var toggleConversationWindow: ((Conversation) -> Void)?
  var showGroup: (() -> Void)?
  var minimizeGroup: (() -> Void)?
  var arrangeGroup: (() -> Void)?
  var groupScreen: NSScreen? { panel.screen }
  private var pillWidth: CGFloat { store.group.pins.isEmpty ? 96 : 128 }
  var isTriggerClick: ((NSPoint) -> Bool)?

  init(store: AppStore) {
    self.store = store
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let defaults = UserDefaults.standard
    presentation = FloatingPresentation(
      keepFloating: defaults.object(forKey: "showFloating") as? Bool ?? false)
    let x = defaults.object(forKey: "floatingX") as? Double ?? screen.maxX - 116
    let y = defaults.object(forKey: "floatingY") as? Double ?? screen.midY
    collapsedOrigin = NSPoint(x: x, y: y)
    panel = UtilityPanel(
      contentRect: NSRect(origin: collapsedOrigin, size: NSSize(width: 96, height: 48)),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    details = UtilityPanel(
      contentRect: NSRect(x: x, y: y, width: 420, height: 1),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    for window in [panel, details] {
      window.delegate = self
      window.level = .floating
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = true
      window.hidesOnDeactivate = false
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    panel.title = "AX Widget · Usage"
    details.title = "AX Widget · Conversations"
    subscription = store.$snapshot.sink { [weak self] snapshot in self?.update(snapshot) }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      Task { @MainActor in self?.outsideClick() }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .keyDown,
    ]) { [weak self] event in
      if event.type == .keyDown, event.keyCode == 53,
        event.window === self?.panel || event.window === self?.details
      {
        self?.collapse()
        return nil
      }
      if event.type != .keyDown, event.window !== self?.panel && event.window !== self?.details {
        self?.outsideClick()
      }
      return event
    }
    collapse()
  }

  func setKeepFloating(_ keep: Bool) {
    presentation.keepFloating = keep
    UserDefaults.standard.set(keep, forKey: "showFloating")
    update(store.snapshot)
    applyVisibility()
  }

  func toggle() {
    if expanded { collapse() } else { expand() }
  }

  private func applyVisibility() {
    if presentation.usageVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    if presentation.conversationsVisible {
      details.orderFrontRegardless()
    } else {
      details.orderOut(nil)
    }
  }

  func expand() {
    guard !expanded else { return }
    collapsedOrigin = panel.frame.origin
    presentation.open()
    let measurement = NSHostingView(
      rootView: ConversationsView(
        snapshot: store.snapshot, open: { _ in }, togglePin: { _ in }, toggleWindowGroup: { _ in }
      )
      .frame(width: 384).fixedSize(horizontal: false, vertical: true))
    fitContent(measurement.fittingSize.height + 27 + PanelContent.headerHeight)
    update(store.snapshot)
    panel.orderFrontRegardless()
    details.makeKeyAndOrderFront(nil)
  }

  func collapse() {
    presentation.close()
    details.orderOut(nil)
    let screen =
      panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    collapsedOrigin.x = min(max(collapsedOrigin.x, screen.minX + 8), screen.maxX - pillWidth - 8)
    collapsedOrigin.y = min(max(collapsedOrigin.y, screen.minY + 8), screen.maxY - 56)
    panel.setFrame(
      NSRect(origin: collapsedOrigin, size: NSSize(width: pillWidth, height: 48)), display: true)
    update(store.snapshot)
    applyVisibility()
  }

  private func update(_ snapshot: Snapshot) {
    if panel.frame.width != pillWidth {
      var frame = panel.frame
      frame.origin.x += frame.width - pillWidth
      frame.size.width = pillWidth
      panel.setFrame(frame, display: true)
      collapsedOrigin.x = frame.minX
    }
    let root = CollapsedView(
      snapshot: snapshot,
      showGroup: { [weak self] in self?.showGroup?() },
      minimizeGroup: { [weak self] in self?.minimizeGroup?() },
      arrangeGroup: { [weak self] in self?.arrangeGroup?() })
    if let host = panel.contentView as? CollapsedHost {
      host.rootView = root
      host.hasGroup = !store.group.pins.isEmpty
    } else {
      let host = CollapsedHost(rootView: root)
      host.hasGroup = !store.group.pins.isEmpty
      host.clicked = { [weak self] in
        guard let self else { return }
        if self.expanded { self.collapse() } else { self.expand() }
      }
      host.moved = { [weak self] in self?.rememberPosition() }
      panel.contentView = host
    }
    if expanded {
      if let host = details.contentView as? NSHostingView<PanelContent> {
        host.rootView = content(snapshot)
      } else {
        let host = NSHostingView(rootView: content(snapshot))
        // SwiftUI's native glass composites separately from its content clip.
        // Clip the actual window host too, so no rectangular backing leaks
        // beyond the rounded surface when another window is underneath it.
        host.wantsLayer = true
        host.layer?.cornerRadius = 17
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        host.focusRingType = .none
        details.contentView = host
      }
    }
  }

  private func content(_ snapshot: Snapshot) -> PanelContent {
    PanelContent(
      snapshot: snapshot, heightChanged: { [weak self] height in self?.fitContent(height) },
      keepFloating: keepFloating,
      toggleFloating: { [weak self] in
        guard let self else { return }
        self.setKeepFloating(!self.keepFloating)
      },
      newConversation: { [weak self] provider in self?.newConversation?(provider) },
      attachTask: { [weak self] id in self?.attachTask(id) },
      answer: answerQuestion,
      togglePin: { [weak self] in self?.toggleConversationPin?($0) },
      toggleWindowGroup: { [weak self] in self?.toggleConversationWindow?($0) },
      showGroup: { [weak self] in self?.showGroup?() },
      minimizeGroup: { [weak self] in self?.minimizeGroup?() },
      arrangeGroup: { [weak self] in self?.arrangeGroup?() },
      collapse: { [weak self] in self?.collapse() },
      open: { [weak self] conversation in
        self?.openConversation?(conversation)
      })
  }

  private func attachTask(_ id: String) {
    guard let executable = AxClient.executable(),
      let terminal = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.Terminal")
    else {
      store.reportGroupError(AttachCommand.Error.unavailable)
      return
    }
    do {
      let file = try AttachCommand.write(
        id: id, executable: executable,
        config: ProcessInfo.processInfo.environment["AX_CONFIG"])
      NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init()) {
        [weak self] _, error in
        if let error {
          try? FileManager.default.removeItem(at: file)
          Task { @MainActor in self?.store.reportGroupError(error) }
        }
      }
    } catch { store.reportGroupError(error) }
  }

  private func fitContent(_ naturalHeight: CGFloat) {
    guard expanded, naturalHeight.isFinite, naturalHeight > 0,
      let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    else { return }
    contentHeight = naturalHeight
    let gap: CGFloat = 8
    // A pill placed at the very bottom needs a little room to open below it.
    let minimum = min(naturalHeight, 160, screen.height - 84)
    let requiredY = screen.minY + 12 + gap + minimum
    if panel.frame.minY < requiredY {
      panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: requiredY))
    }
    let height = min(naturalHeight, panel.frame.minY - gap - screen.minY - 12)
    let x = min(max(screen.minX + 12, panel.frame.maxX - 420), screen.maxX - 432)
    let frame = NSRect(x: x, y: panel.frame.minY - gap - height, width: 420, height: height)
    if details.frame != frame {
      details.setFrame(frame, display: true)
      details.invalidateShadow()
    }
  }

  private func outsideClick() {
    // Let the status button handle its own toggle; collapsing on mouse-down
    // would otherwise reopen the panel on the same click's mouse-up.
    if isTriggerClick?(NSEvent.mouseLocation) == true { return }
    if expanded, !panel.frame.contains(NSEvent.mouseLocation),
      !details.frame.contains(NSEvent.mouseLocation)
    {
      collapse()
    }
  }

  private func rememberPosition() {
    collapsedOrigin = panel.frame.origin
    UserDefaults.standard.set(collapsedOrigin.x, forKey: "floatingX")
    UserDefaults.standard.set(collapsedOrigin.y, forKey: "floatingY")
    if expanded { fitContent(contentHeight) }
  }
}
