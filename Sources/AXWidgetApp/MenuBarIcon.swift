import AppKit

enum MenuBarIcon {
  /// A monochrome axe, drawn as a vector so it stays sharp at menu-bar scale.
  static var axe: NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      let transform = AffineTransform(
        translationByX: 9, byY: 9)
      (transform as NSAffineTransform).concat()
      let tilt = NSAffineTransform()
      tilt.rotate(byDegrees: -35)
      tilt.scale(by: 0.78)
      tilt.translateX(by: -10, yBy: -10)
      tilt.concat()
      NSColor.white.setFill()
      NSBezierPath(
        roundedRect: NSRect(x: 8.6, y: 0.8, width: 2.4, height: 16.2),
        xRadius: 1.1, yRadius: 1.1
      ).fill()
      let head = NSBezierPath()
      head.move(to: NSPoint(x: 6.1, y: 12.7))
      head.line(to: NSPoint(x: 10.3, y: 12.7))
      head.line(to: NSPoint(x: 17.1, y: 10.4))
      head.curve(
        to: NSPoint(x: 17.1, y: 19.1),
        controlPoint1: NSPoint(x: 19.7, y: 12.9),
        controlPoint2: NSPoint(x: 19.7, y: 16.6))
      head.line(to: NSPoint(x: 10.3, y: 16.9))
      head.line(to: NSPoint(x: 6.1, y: 16.9))
      head.close()
      head.fill()
      return true
    }
    // Deliberately white, including when the menu bar is using its light appearance.
    image.isTemplate = false
    image.accessibilityDescription = "ax"
    return image
  }
}
