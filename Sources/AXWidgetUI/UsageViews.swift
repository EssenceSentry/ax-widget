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
      Circle().fill(palette.frost ? Color.clear : palette.background.opacity(0.88))
      if provider == .codex {
        ring(snapshot.codex, color: palette.blue, inset: 2)
      } else {
        ring(snapshot.claudeWeekly, color: palette.violet, inset: 1)
        ring(snapshot.claudeFiveHour, color: palette.peach, inset: 6)
      }
      ProviderGlyph(provider, size: size * 0.47, tint: palette.foreground)
      if attention {
        Circle().fill(palette.blue).frame(width: 6, height: 6)
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
    let value = allowance?.displayRemaining()
    return ZStack {
      Circle().stroke(palette.track, style: StrokeStyle(lineWidth: 2.5))
      if let value {
        Circle().trim(from: 0, to: value / 100)
          .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .opacity(allowance?.isCached() == true ? 0.7 : 1)
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
        return "\(allowance.windowLabel): \(usageHelp(allowance))"
      }).joined(separator: "\n")
  }
}

public struct CollapsedView: View {
  public var snapshot: Snapshot
  public var nativeEffects: Bool
  public var showGroup: (() -> Void)?
  public var minimizeGroup: (() -> Void)?
  public var arrangeGroup: (() -> Void)?
  @Environment(\.colorScheme) private var scheme
  public init(
    snapshot: Snapshot, nativeEffects: Bool = true, showGroup: (() -> Void)? = nil,
    minimizeGroup: (() -> Void)? = nil, arrangeGroup: (() -> Void)? = nil
  ) {
    self.snapshot = snapshot
    self.nativeEffects = nativeEffects
    self.showGroup = showGroup
    self.minimizeGroup = minimizeGroup
    self.arrangeGroup = arrangeGroup
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
      if snapshot.windowGroupConversationIDs?.isEmpty == false {
        Button {
          showGroup?()
        } label: {
          Image(systemName: "rectangle.on.rectangle").font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.foreground).frame(width: 24, height: 40)
        }.buttonStyle(.plain).help("Bring all grouped conversation windows forward")
          .accessibilityLabel("Show conversation group")
          .contextMenu {
            Button("Show group") { showGroup?() }
            Button("Minimize group") { minimizeGroup?() }
            Button("Arrange side by side") { arrangeGroup?() }
          }
      }
    }.padding(4)
      .background {
        if palette.frost {
          if !nativeEffects { Capsule().fill(palette.background) }
        } else {
          Capsule().fill(palette.background.opacity(0.25))
        }
      }
      .modifier(NativeFrostSurface(enabled: palette.frost && nativeEffects, cornerRadius: 24))
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
      HStack(spacing: 3) {
        Text("Codex \(percent(snapshot.codex))")
        if snapshot.codex?.isCached() == true {
          Image(systemName: "clock").font(.system(size: 8))
        }
      }.help(usageHelp(snapshot.codex)).accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex: \(usageHelp(snapshot.codex))")
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
  allowance?.displayRemaining().map { "\(Int($0.rounded()))%" } ?? "—"
}

public func usageHelp(_ allowance: Allowance?) -> String {
  guard let allowance else { return "Allowance unavailable" }
  let value =
    allowance.displayRemaining().map { "\(Int($0.rounded()))% remaining" } ?? "Unknown or stale"
  let prefix = allowance.isCached() ? "Cached · last observed " : ""
  let age =
    allowance.observed.map { "observed \($0.formatted(.relative(presentation: .numeric)))" }
    ?? "not observed"
  return "\(prefix)\(value) · \(reset(allowance)) · \(age)"
}

public func reset(_ allowance: Allowance?) -> String {
  guard let date = allowance?.resets else { return "Reset time unavailable" }
  return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
}
