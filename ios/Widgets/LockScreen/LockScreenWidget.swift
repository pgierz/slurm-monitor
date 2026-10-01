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
        if context.isPreview {
            completion(LockScreenEntry.sample())
            return
        }
        Task {
            let entry: LockScreenEntry = await LockScreenProvider.cachedEntry()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> Void) {
        Task {
            let timeline: Timeline<LockScreenEntry> = await LockScreenProvider.loadTimeline()
            completion(timeline)
        }
    }

    /// The entry outside the widget gallery: for each family the cached
    /// snapshot if there is one, otherwise the sample.
    static func cachedEntry() async -> LockScreenEntry {
        let now = Date()
        let sample: LockScreenEntry = LockScreenEntry.sample()
        let nodes: WidgetContent<NodesData>? = await FamilyTimeline.cachedContent(now: now) { (loader: SnapshotLoader) in
            await loader.nodes()
        }
        let queue: WidgetContent<QueueData>? = await FamilyTimeline.cachedContent(now: now) { (loader: SnapshotLoader) in
            await loader.queue()
        }
        return LockScreenEntry(date: now, nodes: nodes ?? sample.nodes, queue: queue ?? sample.queue)
    }

    /// The entries for two contents loaded at `now`: the one for now and
    /// one at each moment at which either turns stale.
    static func entries(nodes: WidgetContent<NodesData>, queue: WidgetContent<QueueData>, now: Date) -> [LockScreenEntry] {
        var dates: [Date] = [now]
        let staleDates: [Date?] = [
            FamilyTimeline.staleDate(for: nodes, after: now),
            FamilyTimeline.staleDate(for: queue, after: now),
        ]
        for candidate in staleDates {
            if let date = candidate, !dates.contains(date) {
                dates.append(date)
            }
        }
        dates.sort()
        return dates.map { (date: Date) -> LockScreenEntry in
            LockScreenEntry(
                date: date,
                nodes: FamilyTimeline.content(nodes, at: date),
                queue: FamilyTimeline.content(queue, at: date)
            )
        }
    }

    /// Loads the two families side by side, each within the deadline.
    /// Refreshed at the earlier of the two families' times, so that
    /// "VPN needed" in either is retried soon.
    static func loadTimeline() async -> Timeline<LockScreenEntry> {
        let loader = SnapshotLoader.live()
        async let nodesLoad: WidgetContent<NodesData> = FamilyTimeline.load(loader: loader) { (source: SnapshotLoader) in
            await source.nodes()
        }
        async let queueLoad: WidgetContent<QueueData> = FamilyTimeline.load(loader: loader) { (source: SnapshotLoader) in
            await source.queue()
        }
        let nodes: WidgetContent<NodesData> = await nodesLoad
        let queue: WidgetContent<QueueData> = await queueLoad
        let now = Date()
        let entries: [LockScreenEntry] = LockScreenProvider.entries(nodes: nodes, queue: queue, now: now)
        let nodesNext: Date = FamilyTimeline.nextRefresh(after: now, content: nodes)
        let queueNext: Date = FamilyTimeline.nextRefresh(after: now, content: queue)
        return Timeline(entries: entries, policy: .after(min(nodesNext, queueNext)))
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
