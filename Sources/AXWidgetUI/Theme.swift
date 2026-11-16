import AXWidgetCore
import AppKit
import SwiftUI

public struct Palette {
  public var dark: Bool
  public var frost: Bool
  public init(_ appearance: Appearance, scheme: ColorScheme) {
    dark = appearance == .carbon || ([.system, .frost].contains(appearance) && scheme == .dark)
    frost = appearance == .frost
  }
  public var background: Color {
    if frost { return Color(nsColor: .windowBackgroundColor) }
    return dark
      ? Color(red: 0.105, green: 0.113, blue: 0.125) : Color(red: 0.975, green: 0.966, blue: 0.949)
  }
  public var foreground: Color {
    frost ? .primary : (dark ? Color(white: 0.94) : Color(white: 0.14))
  }
  public var secondary: Color {
    frost ? .secondary : (dark ? Color(white: 0.66) : Color(white: 0.44))
  }
  public var separator: Color {
    frost
      ? Color(nsColor: .separatorColor)
      : (dark ? Color.white.opacity(0.13) : Color.black.opacity(0.10))
  }
  public var track: Color {
    frost
      ? Color.primary.opacity(0.12)
      : (dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10))
  }
  public var surfaceOpacity: Double { 0.88 }
  public var blue: Color { Color(red: 0.26, green: 0.62, blue: 0.98) }
  public var blueText: Color { dark ? blue : Color(red: 0.14, green: 0.40, blue: 0.72) }
  public var peach: Color { Color(red: 0.96, green: 0.58, blue: 0.42) }
  public var violet: Color { Color(red: 0.65, green: 0.53, blue: 0.91) }
  public var peachText: Color { dark ? peach : Color(red: 0.66, green: 0.33, blue: 0.20) }
  public var violetText: Color { dark ? violet : Color(red: 0.43, green: 0.32, blue: 0.66) }
}

extension Appearance {
  public var colorScheme: ColorScheme? {
    switch self {
    case .system, .frost: nil
    case .carbon: .dark
    case .porcelain: .light
    }
  }
}

public struct NativeMaterial: NSViewRepresentable {
  let appearance: Appearance
  public init(appearance: Appearance = .system) { self.appearance = appearance }
  public func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    applyAppearance(to: view)
    return view
  }
  public func updateNSView(_ view: NSVisualEffectView, context: Context) {
    applyAppearance(to: view)
  }
  private func applyAppearance(to view: NSVisualEffectView) {
    switch appearance {
    case .system, .frost: view.appearance = nil
    case .carbon: view.appearance = NSAppearance(named: .darkAqua)
    case .porcelain: view.appearance = NSAppearance(named: .aqua)
    }
  }
}

/// Let macOS render the glass, its edge treatment, and its contrast adaptation.
struct NativeFrostSurface: ViewModifier {
  var enabled: Bool
  var cornerRadius: CGFloat
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  @ViewBuilder func body(content: Content) -> some View {
    if enabled {
      if #available(macOS 26.0, *), !reduceTransparency {
        content.glassEffect(
          .regular,
          in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      } else {
        content.background {
          if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
          } else {
            NativeMaterial(appearance: .system)
          }
        }.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      }
    } else {
      content
    }
  }
}

public func relativeAge(_ date: Date, now: Date = Date()) -> String {
  let elapsed = max(0, now.timeIntervalSince(date))
  if elapsed < 60 { return "now" }
  if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
  if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
  return "\(Int(elapsed / 86400))d ago"
}
