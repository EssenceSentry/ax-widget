import AppKit
import Testing

@testable import AXWidgetUI

@Test @MainActor func ringClickAndDragRemainDistinctEvenWhenReturningToThePressPoint() throws {
  let surface = FloatingDragSurface.Surface()
  var actions: [FloatingDragEvent] = []
  surface.handle = { actions.append($0) }

  // Feed events directly to the view. Nothing is posted to the user's desktop.
  func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
      with: type, location: CGPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
  }

  surface.mouseDown(with: try event(.leftMouseDown, x: 10))
  surface.mouseDragged(with: try event(.leftMouseDragged, x: 11))
  surface.mouseUp(with: try event(.leftMouseUp, x: 12))
  #expect(actions == [.clicked])

  actions.removeAll()
  surface.mouseDown(with: try event(.leftMouseDown, x: 10))
  surface.mouseDragged(with: try event(.leftMouseDragged, x: 26))
  surface.mouseDragged(with: try event(.leftMouseDragged, x: 35))
  surface.mouseUp(with: try event(.leftMouseUp, x: 10))
  #expect(actions == [
    .began, .moved(CGSize(width: 16, height: 0)), .moved(CGSize(width: 25, height: 0)),
    .moved(.zero), .ended,
  ])
}
