import AXWidgetCore
import SwiftUI

public struct SmallUsageWidget: View {
  public var snapshot: Snapshot
  @Environment(\.colorScheme) private var scheme
  public init(snapshot: Snapshot) { self.snapshot = snapshot }
  public var body: some View {
    let palette = Palette(snapshot.appearance, scheme: scheme)
    VStack(spacing: 12) {
      HStack(alignment: .top, spacing: 14) {
        VStack(spacing: 8) {
          ProviderGauge(
            .codex, snapshot: snapshot, palette: palette, size: 50,
            attention: snapshot.conversations.contains {
              $0.provider == .codex && $0.needsAttention
            })
          Text(percent(snapshot.codex)).foregroundStyle(palette.foreground)
            .help(reset(snapshot.codex))
            .accessibilityLabel("Codex: \(percent(snapshot.codex)) remaining")
        }.frame(maxWidth: .infinity)
        VStack(spacing: 8) {
          ProviderGauge(
            .claude, snapshot: snapshot, palette: palette, size: 50,
            attention: snapshot.conversations.contains {
              $0.provider == .claude && $0.needsAttention
            })
          HStack(spacing: 5) {
            Text(percent(snapshot.claudeFiveHour)).foregroundStyle(palette.peachText)
              .help("Five-hour allowance · \(reset(snapshot.claudeFiveHour))")
            Text(percent(snapshot.claudeWeekly)).foregroundStyle(palette.violetText)
              .help("Weekly allowance · \(reset(snapshot.claudeWeekly))")
          }.accessibilityElement(children: .ignore)
            .accessibilityLabel(
              "Claude: five-hour \(percent(snapshot.claudeFiveHour)), weekly \(percent(snapshot.claudeWeekly)) remaining"
            )
        }.frame(maxWidth: .infinity)
      }
      .font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(
        0.85)
      Text("Remaining").font(.system(size: 9)).foregroundStyle(palette.secondary)
        .help("Updated \(snapshot.generated.formatted(.dateTime.hour().minute()))")
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .preferredColorScheme(snapshot.appearance.colorScheme)
  }
}
