import SlurmKit
import SwiftUI
import WidgetKit

/// The "last seen" line of the QOS widget.
enum QosWidgetLogic {
    /// Key figures for the "VPN needed" footer: the busiest QOS, `12h 14.2k / 18k`.
    static func lastSeen(_ data: QosData) -> String {
        guard let first = data.qos.first else { return Format.dash }
        return first.name + " " + first.usageText
    }
}

/// The QOS widget (medium only), in whatever state `content` is.
/// The screenshot tests construct this directly.
struct QosFamilyView: View {
    let content: WidgetContent<QosData>
    var timeZone: TimeZone = TimeZone.current

    var body: some View {
        FamilyWidgetView(
            kind: .qos,
            size: .medium,
            content: content,
            title: "QOS · CPUs in use",
            timeZone: timeZone,
            lastSeen: { (data: QosData) -> String in
                QosWidgetLogic.lastSeen(data)
            },
            live: { (data: QosData, isStale: Bool) in
                QosMediumView(data: data, isStale: isStale)
            }
        )
    }
}

struct QosWidget: Widget {
    let kind: String = "QosWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: FamilyStaticProvider<QosData>(
                sample: SampleData.qos.data,
                fetch: { (loader: SnapshotLoader) in await loader.qos() }
            )
        ) { (entry: FamilyEntry<QosData, NoConfiguration>) in
            QosFamilyView(content: entry.content)
        }
        .configurationDisplayName("QOS")
        .description("CPUs in use against the limit of each QOS, and your fairshare.")
        .supportedFamilies([.systemMedium])
    }
}
