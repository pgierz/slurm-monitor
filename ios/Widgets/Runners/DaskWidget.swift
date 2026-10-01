import AppIntents
import SlurmKit
import SwiftUI
import WidgetKit

/// Column widths shared by the heading and the rows of the Dask table.
enum DaskColumns {
    static let dotSize: CGFloat = 7
    static let dotGap: CGFloat = 6
    static let workersWidth: CGFloat = 52
    static let timeWidth: CGFloat = 58
}

/// Medium: one row per cluster, up to three.
struct DaskMediumView: View {
    static let maxRows = 3

    let data: RunnersData
    var isStale: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if shownClusters.isEmpty {
                emptyMessage
            } else {
                table
                Spacer(minLength: 0)
                FooterRow(left: reduced ? "filled dot: scheduler alive" : "dot: scheduler alive", right: moreText, rightColour: Theme.secondaryText, dimmed: isStale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var shownClusters: [DaskCluster] {
        Array(data.dask.clusters.prefix(DaskMediumView.maxRows))
    }

    private var moreText: String {
        let more: Int = data.dask.clusters.count - shownClusters.count
        return more > 0 ? "and \(more) more" : ""
    }

    private var emptyMessage: some View {
        Text("No clusters running")
            .font(Theme.footerFont)
            .foregroundStyle(Theme.secondary(reduced: reduced))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            headings
            ForEach(0..<shownClusters.count, id: \.self) { (index: Int) in
                DaskClusterRow(cluster: shownClusters[index], isStale: isStale)
            }
        }
    }

    private var headings: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SectionLabel(text: "cluster")
                .padding(.leading, DaskColumns.dotSize + DaskColumns.dotGap)
            Spacer(minLength: 4)
            SectionLabel(text: "workers")
                .frame(width: DaskColumns.workersWidth, alignment: .trailing)
            SectionLabel(text: "time left")
                .frame(width: DaskColumns.timeWidth, alignment: .trailing)
        }
    }
}

/// One cluster: scheduler dot, `owner · id`, workers, walltime left.
struct DaskClusterRow: View {
    let cluster: DaskCluster
    var isStale: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            nameColumn
            Spacer(minLength: 4)
            figure(cluster.workersText, colour: Theme.primaryText)
                .frame(width: DaskColumns.workersWidth, alignment: .trailing)
            figure(cluster.walltimeLeftText, colour: timeColour)
                .frame(width: DaskColumns.timeWidth, alignment: .trailing)
        }
    }

    private var dotColour: Color {
        cluster.schedulerAlive ? Theme.running : Theme.down
    }

    /// In reduced colour a dead scheduler is a hollow dot, as blue and
    /// light red can no longer be told apart.
    private var dotFill: Color {
        if reduced && !cluster.schedulerAlive {
            return Color.clear
        }
        return Theme.figure(dotColour, dimmed: isStale, reduced: reduced)
    }

    private var dotOutline: Color {
        if reduced && !cluster.schedulerAlive {
            return Theme.figure(dotColour, dimmed: isStale, reduced: reduced)
        }
        return Color.clear
    }

    private var timeColour: Color {
        cluster.isNearWalltime ? Theme.pending : Theme.primaryText
    }

    private var nameColumn: some View {
        HStack(alignment: .center, spacing: DaskColumns.dotGap) {
            Circle()
                .fill(dotFill)
                .frame(width: DaskColumns.dotSize, height: DaskColumns.dotSize)
                .overlay(Circle().strokeBorder(dotOutline, lineWidth: 1))
            Text(cluster.label)
                .font(Theme.figureFont(size: 11, weight: .medium))
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale, reduced: reduced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func figure(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(Theme.footerValueFont)
            .foregroundStyle(Theme.figure(colour, dimmed: isStale, reduced: reduced))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// The Dask widget in whatever state `content` is.
/// The screenshot tests construct this directly.
struct DaskFamilyView: View {
    let content: WidgetContent<RunnersData>
    var timeZone: TimeZone = TimeZone.autoupdatingCurrent

    var body: some View {
        FamilyWidgetView(
            kind: .runners,
            size: .medium,
            content: content,
            title: "Dask clusters",
            liveTitle: { (data: RunnersData) -> String in
                "Dask clusters · \(data.dask.clusters.count)"
            },
            timeZone: timeZone,
            lastSeen: { (data: RunnersData) -> String in
                DaskFamilyView.lastSeen(data)
            },
            live: { (data: RunnersData, isStale: Bool) in
                DaskMediumView(data: data, isStale: isStale)
            }
        )
    }

    /// Key figures for the "VPN needed" footer: `3 clusters`.
    static func lastSeen(_ data: RunnersData) -> String {
        let count: Int = data.dask.clusters.count
        return count == 1 ? "1 cluster" : "\(count) clusters"
    }
}

struct DaskWidget: Widget {
    let kind: String = "DaskWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: DaskConfigurationIntent.self,
            provider: RunnersProvider.daskProvider()
        ) { (entry: FamilyEntry<RunnersData, DaskConfigurationIntent>) in
            DaskFamilyView(content: entry.content)
        }
        .configurationDisplayName("Dask clusters")
        .description("Dask clusters with their workers and the walltime left.")
        .supportedFamilies([.systemMedium])
    }
}
