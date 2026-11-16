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
        completion(Timeline(entries: [Entry(date: now, snapshot: SnapshotStore.read())],
                            policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct UsageWidget: Widget {
    let kind = "AXUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SmallUsageWidget(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { WidgetBackground(appearance: entry.snapshot.appearance) }
                .widgetURL(URL(string: "ax-widget://show"))
        }
        .configurationDisplayName("AX Widget · Usage")
        .description("Remaining Claude and Codex allowance, with reset times.")
        .supportedFamilies([.systemSmall])
    }
}

struct ConversationsWidget: Widget {
    let kind = "AXConversationsWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            LargeConversationWidget(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { WidgetBackground(appearance: entry.snapshot.appearance) }
                .widgetURL(URL(string: "ax-widget://show"))
        }
        .configurationDisplayName("AX Widget · Conversations")
        .description("Recent agent updates and task progress. Click a title to open its original conversation.")
        .supportedFamilies([.systemLarge])
    }
}

private struct WidgetBackground: View {
    let appearance: Appearance
    @Environment(\.colorScheme) private var scheme
    var body: some View { Palette(appearance, scheme: scheme).background }
}

@main struct AXWidgets: WidgetBundle {
    var body: some Widget { UsageWidget(); ConversationsWidget() }
}
