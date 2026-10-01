import SlurmKit
import SwiftUI
import WidgetKit

/// The entry of the Lock Screen widget: nodes for the gauge, the queue for
/// the texts.
struct LockScreenEntry: TimelineEntry {
    let date: Date
    let nodes: WidgetContent<NodesData>
    let queue: WidgetContent<QueueData>

    /// Sample data, shown as live, for placeholders and the widget gallery.
    static func sample() -> LockScreenEntry {
        LockScreenEntry(
            date: Date(),
            nodes: WidgetContent<NodesData>.live(SampleData.nodes.data, generatedAt: SampleData.generatedAt),
            queue: WidgetContent<QueueData>.live(SampleData.queue.data, generatedAt: SampleData.generatedAt)
        )
    }
}

/// Loads both families for the Lock Screen widget.
struct LockScreenProvider: TimelineProvider {
    typealias Entry = LockScreenEntry

    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry.sample()
    }

    func getSnapshot(in context: Context, completion: @escaping (LockScreenEntry) -> Void) {
        completion(LockScreenEntry.sample())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> Void) {
        Task {
            let timeline: Timeline<LockScreenEntry> = await LockScreenProvider.loadTimeline()
            completion(timeline)
        }
    }

    /// One entry; refreshed at the earlier of the two families' times, so
    /// that "VPN needed" in either is retried soon.
    static func loadTimeline() async -> Timeline<LockScreenEntry> {
        let loader = SnapshotLoader.live()
        let nodes: WidgetContent<NodesData> = await loader.nodes()
        let queue: WidgetContent<QueueData> = await loader.queue()
        let now = Date()
        let entry = LockScreenEntry(date: now, nodes: nodes, queue: queue)
        let nodesNext: Date = FamilyTimeline.nextRefresh(after: now, content: nodes)
        let queueNext: Date = FamilyTimeline.nextRefresh(after: now, content: queue)
        return Timeline(entries: [entry], policy: .after(min(nodesNext, queueNext)))
    }
}

/// Top-level entry view: the only place that reads the widget family.
struct LockScreenEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LockScreenEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            LockAccessoryContainer(kind: .nodes) {
                LockCircularView(nodes: entry.nodes, showsBackdrop: true)
            }
        case .accessoryInline:
            LockAccessoryContainer(kind: .queue) {
                LockInlineView(queue: entry.queue)
            }
        default:
            LockAccessoryContainer(kind: .queue) {
                LockRectangularView(queue: entry.queue)
            }
        }
    }
}

struct LockScreenWidget: Widget {
    let kind: String = "LockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockScreenProvider()) { (entry: LockScreenEntry) in
            LockScreenEntryView(entry: entry)
        }
        .configurationDisplayName("Cluster at a glance")
        .description("Allocated nodes, your next job start, and your running and pending jobs.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
