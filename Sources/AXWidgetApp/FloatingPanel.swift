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
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
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
  private var subscription: AnyCancellable?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var expanded = false
  private var expandedTop: CGFloat = 0
  private var collapsedOrigin: NSPoint
  var openConversation: ((Conversation) -> Void)?

  init(store: AppStore) {
    self.store = store
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let defaults = UserDefaults.standard
    let x = defaults.object(forKey: "floatingX") as? Double ?? screen.maxX - 116
    let y = defaults.object(forKey: "floatingY") as? Double ?? screen.midY
    collapsedOrigin = NSPoint(x: x, y: y)
    panel = UtilityPanel(
      contentRect: NSRect(origin: collapsedOrigin, size: NSSize(width: 96, height: 48)),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    panel.delegate = self
    panel.title = "AX Widget"
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    subscription = store.$snapshot.sink { [weak self] snapshot in self?.update(snapshot) }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      Task { @MainActor in self?.outsideClick() }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .keyDown,
    ]) { [weak self] event in
      if event.type == .keyDown, event.keyCode == 53 {
        self?.collapse()
        return nil
      }
      if event.window !== self?.panel { self?.outsideClick() }
      return event
    }
    collapse()
  }

  func setVisible(_ visible: Bool) {
    if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
  }

  func expand() {
    guard !expanded else { return }
    collapsedOrigin = panel.frame.origin
    expanded = true
    let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
    let measurement = NSHostingView(
      rootView: ConversationsView(snapshot: store.snapshot, open: { _ in })
        .frame(width: 384).fixedSize(horizontal: false, vertical: true))
    let height = min(measurement.fittingSize.height + 43, screen.height - 24)
    let frame = NSRect(
      x: min(max(screen.minX + 12, collapsedOrigin.x - 324), screen.maxX - 432),
      y: min(max(screen.minY + 12, collapsedOrigin.y + 48 - height), screen.maxY - height - 12),
      width: 420, height: height)
    expandedTop = frame.maxY
    panel.setFrame(
      frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    update(store.snapshot)
    panel.makeKeyAndOrderFront(nil)
  }

  func collapse() {
    expanded = false
    let screen =
      panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    collapsedOrigin.x = min(max(collapsedOrigin.x, screen.minX + 8), screen.maxX - 104)
    collapsedOrigin.y = min(max(collapsedOrigin.y, screen.minY + 8), screen.maxY - 56)
    panel.setFrame(
      NSRect(origin: collapsedOrigin, size: NSSize(width: 96, height: 48)), display: true)
    update(store.snapshot)
    if UserDefaults.standard.object(forKey: "showFloating") as? Bool != false {
      panel.orderFrontRegardless()
    }
  }

  private func update(_ snapshot: Snapshot) {
    if expanded {
      if let host = panel.contentView as? NSHostingView<PanelContent> {
        host.rootView = content(snapshot)
      } else {
        panel.contentView = NSHostingView(rootView: content(snapshot))
      }
    } else {
      if let host = panel.contentView as? CollapsedHost {
        host.rootView = CollapsedView(snapshot: snapshot)
      } else {
        let host = CollapsedHost(rootView: CollapsedView(snapshot: snapshot))
        host.clicked = { [weak self] in self?.expand() }
        host.moved = { [weak self] in self?.rememberPosition() }
        panel.contentView = host
      }
    }
  }

  private func content(_ snapshot: Snapshot) -> PanelContent {
    PanelContent(
      snapshot: snapshot, heightChanged: { [weak self] height in self?.fitContent(height) },
      collapse: { [weak self] in self?.collapse() },
      open: { [weak self] conversation in
        self?.openConversation?(conversation)
      })
  }

  private func fitContent(_ naturalHeight: CGFloat) {
    guard expanded, naturalHeight.isFinite, naturalHeight > 0,
      let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    else { return }
    let height = min(naturalHeight, screen.height - 24)
    let y = max(screen.minY + 12, min(expandedTop, screen.maxY - 12) - height)
    guard abs(panel.frame.height - height) > 0.5 || abs(panel.frame.minY - y) > 0.5 else { return }
    panel.setFrame(NSRect(x: panel.frame.minX, y: y, width: 420, height: height), display: true)
  }

  private func outsideClick() {
    if expanded, !panel.frame.contains(NSEvent.mouseLocation) { collapse() }
  }

  private func rememberPosition() {
    guard !expanded else { return }
    collapsedOrigin = panel.frame.origin
    UserDefaults.standard.set(collapsedOrigin.x, forKey: "floatingX")
    UserDefaults.standard.set(collapsedOrigin.y, forKey: "floatingY")
  }
}
