import AXWidgetCore
import SwiftUI

public struct SmallUsageWidget: View {
    public var snapshot: Snapshot
    @Environment(\.colorScheme) private var scheme
    public init(snapshot: Snapshot) { self.snapshot = snapshot }
    public var body: some View {
        let palette = Palette(snapshot.appearance, scheme: scheme)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    ProviderGauge(.codex, snapshot: snapshot, palette: palette, size: 43)
                    Text("Codex").font(.system(size: 11, weight: .semibold))
                    Text("\(percent(snapshot.codex)) left").font(.system(size: 10))
                    resetText(snapshot.codex)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    ProviderGauge(.claude, snapshot: snapshot, palette: palette, size: 43)
                    Text("Claude").font(.system(size: 11, weight: .semibold))
                    Text("5h \(percent(snapshot.claudeFiveHour))").font(.system(size: 10))
                    resetText(snapshot.claudeFiveHour)
                    Text("W \(percent(snapshot.claudeWeekly))").font(.system(size: 10))
                    resetText(snapshot.claudeWeekly)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text(snapshot.generated, style: .relative).font(.system(size: 9)).foregroundStyle(palette.secondary)
        }.foregroundStyle(palette.foreground).preferredColorScheme(snapshot.appearance.colorScheme)
    }
    @ViewBuilder private func resetText(_ allowance: Allowance?) -> some View {
        if let date = allowance?.resets {
            Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
        } else { Text("Reset —").font(.system(size: 8)).foregroundStyle(.secondary) }
    }
}

public struct LargeConversationWidget: View {
    public var snapshot: Snapshot
    @Environment(\.colorScheme) private var scheme
    public init(snapshot: Snapshot) { self.snapshot = snapshot }
    public var body: some View {
        let palette = Palette(snapshot.appearance, scheme: scheme)
        VStack(alignment: .leading, spacing: 8) {
            ConversationsView(snapshot: snapshot, compact: true)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("Updated"); Text(snapshot.generated, style: .relative)
            }.font(.system(size: 9)).foregroundStyle(palette.secondary)
        }.preferredColorScheme(snapshot.appearance.colorScheme)
    }
}
