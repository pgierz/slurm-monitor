import AppIntents
import SlurmKit
import SwiftUI
import WidgetKit

/// Titles, the "last seen" line and the fetch of the queue widget.
enum QueueWidgetLogic {
    /// `nil` for a missing or blank partition, which means all partitions.
    static func normalisedPartition(_ text: String?) -> String? {
        guard let text = text else { return nil }
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Header title of the live layout for a size.
    static func title(for data: QueueData, size: WidgetLayoutSize) -> String {
        switch size {
        case .small:
            return "Queue"
        case .medium:
            return "Queue · " + (normalisedPartition(data.partition) ?? "all partitions")
        case .large, .extraLarge:
            if data.mine == nil {
                return "My jobs"
            }
            return "My jobs · " + data.mineLine
        }
    }

    /// Key figures for the "VPN needed" footer: `412 R · 96 PD`.
    static func lastSeen(_ data: QueueData) -> String {
        Format.queueLine(running: data.running, pending: data.pending)
    }

    /// Loads the queue for a configuration. The scope decides only which
    /// user is sent: "mine" leaves it to the client (the username from the
    /// settings), "everyone" sends none and caches under its own key.
    static func fetch(loader: SnapshotLoader, configuration: QueueConfigurationIntent) async -> WidgetContent<QueueData> {
        let partition: String? = normalisedPartition(configuration.partition)
        switch configuration.scope {
        case .mine:
            return await loader.queue(partition: partition)
        case .everyone:
            let client = SlurmClient.live()
            let parameters: [String: String?] = ["partition": partition, "scope": "everyone"]
            let key: String = SnapshotCacheKey.make(family: .queue, parameters: parameters)
            // An empty user is dropped from the query, where nil would be
            // replaced by the username from the settings.
            return await loader.load(key: key) {
                try await client.queue(partition: partition, user: "", qos: nil)
            }
        }
    }
}

/// The queue widget at a given size, in whatever state `content` is.
/// The screenshot tests construct this directly.
struct QueueFamilyView: View {
    let content: WidgetContent<QueueData>
    let size: WidgetLayoutSize
    var timeZone: TimeZone = TimeZone.current

    var body: some View {
        FamilyWidgetView(
            kind: .queue,
            size: size,
            content: content,
            title: WidgetFamilyKind.queue.title,
            liveTitle: { (data: QueueData) -> String in
                QueueWidgetLogic.title(for: data, size: size)
            },
            timeZone: timeZone,
            lastSeen: { (data: QueueData) -> String in
                QueueWidgetLogic.lastSeen(data)
            },
            live: { (data: QueueData, isStale: Bool) in
                liveBody(data, isStale: isStale)
            }
        )
    }

    @ViewBuilder
    private func liveBody(_ data: QueueData, isStale: Bool) -> some View {
        switch size {
        case .small:
            QueueSmallView(data: data, isStale: isStale)
        case .medium:
            QueueMediumView(data: data, isStale: isStale)
        case .large, .extraLarge:
            QueueLargeView(data: data, isStale: isStale, timeZone: timeZone)
        }
    }
}

/// Top-level entry view: the only place that reads the widget family.
struct QueueWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FamilyEntry<QueueData, QueueConfigurationIntent>

    var body: some View {
        QueueFamilyView(content: entry.content, size: WidgetLayoutSize(family))
    }
}

struct QueueWidget: Widget {
    let kind: String = "QueueWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: QueueConfigurationIntent.self,
            provider: FamilyIntentProvider<QueueData, QueueConfigurationIntent>(
                sample: SampleData.queue.data,
                fetch: QueueWidgetLogic.fetch(loader:configuration:)
            )
        ) { (entry: FamilyEntry<QueueData, QueueConfigurationIntent>) in
            QueueWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Queue")
        .description("Running and pending jobs, pending reasons, and your own jobs.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
