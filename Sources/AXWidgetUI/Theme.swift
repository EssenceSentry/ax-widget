import AXWidgetCore
import AppKit
import SwiftUI

public struct Palette {
  public var dark: Bool
  public init(_ appearance: Appearance, scheme: ColorScheme) {
    dark = appearance == .carbon || (appearance == .system && scheme == .dark)
  }
  public var background: Color {
    dark
      ? Color(red: 0.105, green: 0.113, blue: 0.125) : Color(red: 0.975, green: 0.966, blue: 0.949)
  }
  public var foreground: Color { dark ? Color(white: 0.94) : Color(white: 0.14) }
  public var secondary: Color { dark ? Color(white: 0.66) : Color(white: 0.44) }
  public var separator: Color { dark ? Color.white.opacity(0.13) : Color.black.opacity(0.10) }
  public var track: Color { dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10) }
  public var blue: Color { Color(red: 0.26, green: 0.62, blue: 0.98) }
  public var peach: Color { Color(red: 0.96, green: 0.58, blue: 0.42) }
  public var violet: Color { Color(red: 0.65, green: 0.53, blue: 0.91) }
}

extension Appearance {
  public var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .carbon: .dark
    case .porcelain: .light
    }
  }
}

public struct NativeMaterial: NSViewRepresentable {
  public init() {}
  public func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }
  public func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

public func relativeAge(_ date: Date, now: Date = Date()) -> String {
  let elapsed = max(0, now.timeIntervalSince(date))
  if elapsed < 60 { return "now" }
  if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
  if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
  return "\(Int(elapsed / 86400))d ago"
}
