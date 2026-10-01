import SlurmKit
import SwiftUI
import WidgetKit

/// Titles and the "last seen" line of the GPU widget.
enum GpuWidgetLogic {
    /// Header title of the live layout for a size.
    static func title(for data: GpuData, size: WidgetLayoutSize) -> String {
        switch size {
        case .small:
            return "GPU"
        case .medium:
            return "GPU · by card type"
        case .large, .extraLarge:
            return "GPU nodes · " + data.allocatedText
        }
    }

    /// Key figures for the "VPN needed" footer: `14/24 in use`.
    static func lastSeen(_ data: GpuData) -> String {
        data.allocatedText + " in use"
    }
}

/// The GPU widget at a given size, in whatever state `content` is.
/// The screenshot tests construct this directly.
struct GpuFamilyView: View {
    let content: WidgetContent<GpuData>
    let size: WidgetLayoutSize
    var timeZone: TimeZone = TimeZone.autoupdatingCurrent

    var body: some View {
        FamilyWidgetView(
            kind: .gpu,
            size: size,
            content: content,
            title: WidgetFamilyKind.gpu.title,
            liveTitle: { (data: GpuData) -> String in
                GpuWidgetLogic.title(for: data, size: size)
            },
            timeZone: timeZone,
            lastSeen: { (data: GpuData) -> String in
                GpuWidgetLogic.lastSeen(data)
            },
            live: { (data: GpuData, isStale: Bool) in
                liveBody(data, isStale: isStale)
            }
        )
    }

    @ViewBuilder
    private func liveBody(_ data: GpuData, isStale: Bool) -> some View {
        switch size {
        case .small:
            GpuSmallView(data: data, isStale: isStale)
        case .medium:
            GpuMediumView(data: data, isStale: isStale)
        case .large:
            GpuLargeView(data: data, isStale: isStale)
        case .extraLarge:
            GpuExtraLargeView(data: data, isStale: isStale)
        }
    }
}

/// Top-level entry view: the only place that reads the widget family.
struct GpuWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FamilyEntry<GpuData, NoConfiguration>

    var body: some View {
        GpuFamilyView(content: entry.content, size: WidgetLayoutSize(family))
    }
}

struct GpuWidget: Widget {
    let kind: String = "GpuWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: FamilyStaticProvider<GpuData>(
                sample: SampleData.gpu.data,
                fetch: { (loader: SnapshotLoader) in await loader.gpu() }
            )
        ) { (entry: FamilyEntry<GpuData, NoConfiguration>) in
            GpuWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("GPU")
        .description("Allocated cards, per-type use, and the state of every card.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
