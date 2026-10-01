import AppIntents
import SlurmKit
import SwiftUI
import WidgetKit

/// Titles, the "last seen" line and the fetch of the nodes widget.
enum NodesWidgetLogic {
    /// `nil` for a missing or blank partition, which means all partitions.
    static func normalisedPartition(_ text: String?) -> String? {
        guard let text = text else { return nil }
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Header title of the live layout for a size.
    static func title(for data: NodesData, size: WidgetLayoutSize, partition: String?) -> String {
        switch size {
        case .small:
            if let partition = normalisedPartition(partition) {
                return "Nodes · " + partition
            }
            return "Nodes"
        case .medium:
            return "Nodes · by partition"
        case .large, .extraLarge:
            return "Nodes · \(data.total)"
        }
    }

    /// Key figures for the "VPN needed" footer: `198/240 alloc`.
    static func lastSeen(_ data: NodesData) -> String {
        Format.ratio(data.allocated, data.total) + " alloc"
    }

    /// The partition the widget shows: its own, or, when that is left
    /// empty, the default partition from the app's settings; `nil` (all
    /// partitions) when neither is set.
    static func effectivePartition(_ configured: String?, settings: ServerSettings) -> String? {
        normalisedPartition(configured) ?? normalisedPartition(settings.defaultPartition)
    }

    static func fetch(loader: SnapshotLoader, configuration: NodesConfigurationIntent) async -> WidgetContent<NodesData> {
        let partition: String? = effectivePartition(configuration.partition, settings: ServerSettings.load())
        return await loader.nodes(partition: partition)
    }
}

/// The nodes widget at a given size, in whatever state `content` is.
/// The screenshot tests construct this directly.
struct NodesFamilyView: View {
    let content: WidgetContent<NodesData>
    let size: WidgetLayoutSize
    /// The partition the data is for, shown in the title of the small layout.
    var partition: String? = nil
    var timeZone: TimeZone = TimeZone.autoupdatingCurrent

    var body: some View {
        FamilyWidgetView(
            kind: .nodes,
            size: size,
            content: content,
            title: WidgetFamilyKind.nodes.title,
            liveTitle: { (data: NodesData) -> String in
                NodesWidgetLogic.title(for: data, size: size, partition: partition)
            },
            timeZone: timeZone,
            lastSeen: { (data: NodesData) -> String in
                NodesWidgetLogic.lastSeen(data)
            },
            live: { (data: NodesData, isStale: Bool) in
                liveBody(data, isStale: isStale)
            }
        )
    }

    @ViewBuilder
    private func liveBody(_ data: NodesData, isStale: Bool) -> some View {
        switch size {
        case .small:
            NodesSmallView(data: data, isStale: isStale)
        case .medium:
            NodesMediumView(data: data, isStale: isStale)
        case .large, .extraLarge:
            NodesExtraLargeView(data: data, isStale: isStale)
        }
    }
}

/// Top-level entry view: the only place that reads the widget family.
struct NodesWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FamilyEntry<NodesData, NodesConfigurationIntent>

    var body: some View {
        NodesFamilyView(
            content: entry.content,
            size: WidgetLayoutSize(family),
            partition: NodesWidgetLogic.effectivePartition(entry.configuration.partition, settings: ServerSettings.load())
        )
    }
}

struct NodesWidget: Widget {
    let kind: String = "NodesWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: NodesConfigurationIntent.self,
            provider: FamilyIntentProvider<NodesData, NodesConfigurationIntent>(
                sample: SampleData.nodes.data,
                fetch: { (loader: SnapshotLoader, configuration: NodesConfigurationIntent) in
                    await NodesWidgetLogic.fetch(loader: loader, configuration: configuration)
                }
            )
        ) { (entry: FamilyEntry<NodesData, NodesConfigurationIntent>) in
            NodesWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Nodes")
        .description("Allocated, idle, drained and down nodes, by partition.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemExtraLarge])
    }
}
