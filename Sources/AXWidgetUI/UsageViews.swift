import AXWidgetCore
import SwiftUI

public struct ProviderGlyph: View {
  private static let artwork: [Provider: NSImage] = Dictionary(
    uniqueKeysWithValues:
      Provider.allCases.compactMap { provider in
        guard let url = Bundle.module.url(forResource: provider.rawValue, withExtension: "svg"),
          let image = NSImage(contentsOf: url)
        else { return nil }
        return (provider, image)
      })
  public var provider: Provider
  public var size: CGFloat
  public var tint: Color
  public init(_ provider: Provider, size: CGFloat = 21, tint: Color = .primary) {
    self.provider = provider
    self.size = size
    self.tint = tint
  }
  public var body: some View {
    Group {
      if let image = Self.artwork[provider] {
        if provider == .codex {
          tint.mask(Image(nsImage: image).resizable().scaledToFit())
        } else {
          Image(nsImage: image).resizable().scaledToFit()
        }
      } else {
        Image(
          systemName: provider == .codex
            ? "chevron.left.forwardslash.chevron.right" : "sun.max.fill"
        )
        .font(.system(size: size * 0.8, weight: .semibold))
        .foregroundStyle(provider == .claude ? Color.orange : Color.primary)
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}

public struct ProviderGauge: View {
  public var provider: Provider
  public var snapshot: Snapshot
  public var palette: Palette
  public var size: CGFloat
  public var attention: Bool
  public init(
    _ provider: Provider, snapshot: Snapshot, palette: Palette, size: CGFloat = 40,
    attention: Bool = false
  ) {
    self.provider = provider
    self.snapshot = snapshot
    self.palette = palette
    self.size = size
    self.attention = attention
  }
  public var body: some View {
    ZStack {
      Circle().fill(palette.background.opacity(palette.frost ? 0.55 : 0.88))
      if provider == .codex {
        ring(snapshot.codex, color: palette.blue, inset: 2)
      } else {
        ring(snapshot.claudeWeekly, color: palette.violet, inset: 1)
        ring(snapshot.claudeFiveHour, color: palette.peach, inset: 6)
      }
      ProviderGlyph(provider, size: size * 0.47, tint: palette.foreground)
      if attention {
        Circle().fill(.orange).frame(width: 6, height: 6)
          .overlay(Circle().stroke(palette.background, lineWidth: 1.5))
          .offset(x: size * 0.38, y: -size * 0.38)
      }
    }
    .frame(width: size, height: size)
    .help(helpText)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(helpText)
  }

  private func ring(_ allowance: Allowance?, color: Color, inset: CGFloat) -> some View {
    let value = allowance?.remaining()
    return ZStack {
      Circle().stroke(palette.track, style: StrokeStyle(lineWidth: 2.5))
      if let value {
        Circle().trim(from: 0, to: value / 100)
          .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
    }.padding(inset)
  }

  private var helpText: String {
    let windows =
      provider == .codex ? [snapshot.codex] : [snapshot.claudeFiveHour, snapshot.claudeWeekly]
    return
      ([provider.label]
      + windows.map { allowance in
        guard let allowance else { return "Allowance unavailable" }
        let value =
          allowance.remaining().map { "\(Int($0.rounded()))% remaining" } ?? "Unknown or stale"
        let reset =
          allowance.resets.map {
            "resets \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
          } ?? "reset unknown"
        let age =
          allowance.observed.map { "observed \($0.formatted(.relative(presentation: .numeric)))" }
          ?? "not observed"
        return "\(allowance.windowLabel): \(value) · \(reset) · \(age)"
      }).joined(separator: "\n")
  }
}

public struct CollapsedView: View {
  public var snapshot: Snapshot
  public var nativeEffects: Bool
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  public init(snapshot: Snapshot, nativeEffects: Bool = true) {
    self.snapshot = snapshot
    self.nativeEffects = nativeEffects
  }
  public var body: some View {
    let palette = Palette(snapshot.appearance, scheme: scheme)
    HStack(spacing: 8) {
      ForEach(Provider.allCases) { provider in
        ProviderGauge(
          provider, snapshot: snapshot, palette: palette,
          attention: snapshot.conversations.contains {
            $0.provider == provider && $0.needsAttention
          })
      }
    }.padding(4)
      .background {
        if palette.frost {
          ZStack {
            if nativeEffects { NativeMaterial(appearance: snapshot.appearance) }
            palette.background.opacity(
              reduceTransparency || !nativeEffects ? 1 : palette.surfaceOpacity)
          }.clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 0.7))
        } else {
          Capsule().fill(palette.background.opacity(0.25))
        }
      }
      .preferredColorScheme(snapshot.appearance.colorScheme)
  }
}

public struct UsageFooter: View {
  public var snapshot: Snapshot
  public var palette: Palette
  public init(snapshot: Snapshot, palette: Palette) {
    self.snapshot = snapshot
    self.palette = palette
  }
  public var body: some View {
    HStack(spacing: 8) {
      Text("Remaining").foregroundStyle(palette.secondary)
      separator
      Text("Codex \(percent(snapshot.codex))").help(reset(snapshot.codex))
      separator
      Text("Claude 5h \(percent(snapshot.claudeFiveHour)) · Week \(percent(snapshot.claudeWeekly))")
        .help("5h: \(reset(snapshot.claudeFiveHour))\nWeek: \(reset(snapshot.claudeWeekly))")
    }
    .font(.system(size: 10.5)).foregroundStyle(palette.secondary)
    .lineLimit(1).minimumScaleFactor(0.8).accessibilityElement(children: .combine)
  }
  private var separator: some View {
    Rectangle().fill(palette.separator).frame(width: 1, height: 10)
  }
}

public func percent(_ allowance: Allowance?) -> String {
  allowance?.remaining().map { "\(Int($0.rounded()))%" } ?? "—"
}

public func reset(_ allowance: Allowance?) -> String {
  guard let date = allowance?.resets else { return "Reset time unavailable" }
  return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
}
