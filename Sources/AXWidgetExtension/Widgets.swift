import AXWidgetCore
import AXWidgetUI
import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
  let date: Date
  let snapshot: Snapshot
}

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> Entry { Entry(date: Date(), snapshot: .demo()) }
  func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
    completion(Entry(date: Date(), snapshot: context.isPreview ? .demo() : SnapshotStore.read()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
    let now = Date()
    let snapshot = SnapshotStore.read()
    let regularRefresh = now.addingTimeInterval(15 * 60)
    let nextReset = snapshot.allowances.compactMap(\.resets).filter { $0 > now }.min()
    completion(
      Timeline(
        entries: [Entry(date: now, snapshot: snapshot)],
        policy: .after(min(regularRefresh, nextReset ?? regularRefresh))))
  }
}

struct UsageWidget: Widget {
  let kind = "AXUsageWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: Provider()) { entry in
      SmallUsageWidget(snapshot: entry.snapshot)
        .containerBackground(for: .widget) {
          WidgetBackground(appearance: entry.snapshot.appearance)
        }
        .widgetURL(URL(string: "ax-widget://show"))
    }
    .configurationDisplayName("AX Widget · Usage")
    .description("Claude and Codex remaining allowance in two compact provider rings.")
    .supportedFamilies([.systemSmall])
  }
}

private struct WidgetBackground: View {
  let appearance: Appearance
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    let palette = Palette(appearance, scheme: scheme)
    ZStack {
      if palette.frost && !reduceTransparency {
        Rectangle().fill(.regularMaterial)
      } else {
        palette.background
      }
    }.preferredColorScheme(appearance.colorScheme)
  }
}

@main struct AXWidgets: WidgetBundle {
  var body: some Widget {
    UsageWidget()
  }
}
