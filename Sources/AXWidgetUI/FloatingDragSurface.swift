import AppKit
import SwiftUI

public enum FloatingDragEvent: Equatable {
  case clicked, began, ended
  case moved(CGSize)
}

/// Group buttons, tooltips and the scroll view stay outside this pointer interaction.
struct FloatingDragSurface: NSViewRepresentable {
  let handle: (FloatingDragEvent) -> Void

  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) { view.handle = handle }

  final class Surface: NSView {
    var handle: ((FloatingDragEvent) -> Void)?
    private var press: CGPoint?
    private var dragging = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Leave hover and context-menu hit testing to the SwiftUI content underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
      switch window?.currentEvent?.type {
      case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return super.hitTest(point)
      default: return nil
      }
    }

    override func mouseDown(with event: NSEvent) {
      press = screenPoint(event)
      dragging = false
    }

    override func mouseDragged(with event: NSEvent) { track(event) }

    override func mouseUp(with event: NSEvent) {
      guard press != nil else { return }
      track(event)
      press = nil
      handle?(dragging ? .ended : .clicked)
    }

    private func track(_ event: NSEvent) {
      guard let press else { return }
      let point = screenPoint(event)
      let delta = CGSize(width: point.x - press.x, height: point.y - press.y)
      if !dragging {
        guard hypot(delta.width, delta.height) >= 3 else { return }
        dragging = true
        handle?(.began)
      }
      handle?(.moved(delta))
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
      // Both windows move underneath the pointer. Use the event's fixed screen coordinates.
      event.cgEvent?.unflippedLocation
        ?? window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
  }
}
