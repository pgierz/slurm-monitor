import SlurmKit
import SwiftUI

// The small and medium nodes layouts and the legend they share with the
// extra large one. Each draws the body below the header and takes the data
// and the stale flag as plain values.

/// Small: the ring with the allocated percentage, and a two-by-two legend.
/// The ring takes the height the legend leaves, up to 76 pt, so that the
/// layout also fits the small widgets of smaller phones.
struct NodesSmallView: View {
    /// Diameter in the 170 pt widget, and the largest drawn.
    static let maximumRingDiameter: CGFloat = 76
    static let minimumRingDiameter: CGFloat = 44
    /// Line width at the full diameter; scaled with the ring.
    static let ringLineWidth: CGFloat = 9
    /// Two legend lines and the gap between them.
    static let legendHeight: CGFloat = 28
    static let spacing: CGFloat = 6

    let data: NodesData
    var isStale: Bool = false
    @Environment(\.reducedColour) private var reduced

    /// The ring diameter for a body `height` points high.
    static func ringDiameter(forHeight height: CGFloat) -> CGFloat {
        let free: CGFloat = height - legendHeight - spacing
        return min(maximumRingDiameter, max(minimumRingDiameter, free.rounded(.down)))
    }

    static func strokeWidth(forDiameter diameter: CGFloat) -> CGFloat {
        ringLineWidth * diameter / maximumRingDiameter
    }

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            layout(diameter: NodesSmallView.ringDiameter(forHeight: proxy.size.height))
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
    }

    private func layout(diameter: CGFloat) -> some View {
        VStack(alignment: .center, spacing: NodesSmallView.spacing) {
            ring(diameter: diameter)
            legend
        }
    }

    private func ring(diameter: CGFloat) -> some View {
        let lineWidth: CGFloat = NodesSmallView.strokeWidth(forDiameter: diameter)
        return ZStack {
            NodesRing(counts: data.stateCounts, lineWidth: lineWidth, dimmed: isStale)
            centre
                .frame(width: max(20, diameter - 2 * lineWidth - 8))
        }
        .frame(width: diameter, height: diameter)
    }

    private var centre: some View {
        VStack(alignment: .center, spacing: 0) {
            Text(Format.percent(data.allocatedFraction))
                .font(Theme.figureFont(size: 17))
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale, reduced: reduced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("allocated")
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(Theme.secondary(reduced: reduced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 4) {
                item(.allocated, label: "alloc", count: data.allocated)
                item(.idle, label: "idle", count: data.idle)
            }
            HStack(alignment: .center, spacing: 4) {
                item(.drained, label: "drain", count: data.drained)
                item(.down, label: "down", count: data.down)
            }
        }
    }

    private func item(_ state: NodeState, label: String, count: Int) -> some View {
        LegendItem(
            colour: Theme.colour(for: state),
            label: label,
            value: "\(count)",
            dimmed: isStale,
            reducedOpacity: Theme.reducedOpacity(for: state),
            hollowWhenReduced: Theme.isHollowWhenReduced(state)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Legend of the four node states with their totals, below a hairline.
/// `gridStyle` draws the swatches as the node grid draws its cells.
struct NodesLegendFooter: View {
    let counts: NodeStateCounts
    var gridStyle: Bool = false
    var dimmed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.footerGap) {
            Hairline()
            HStack(alignment: .center, spacing: 12) {
                LegendItem(
                    colour: Theme.running,
                    label: "allocated",
                    value: "\(counts.allocated)",
                    dimmed: dimmed,
                    reducedOpacity: Theme.reducedOpacity(for: .allocated)
                )
                LegendItem(
                    colour: gridStyle ? Theme.track : Theme.idleSegment,
                    label: "idle",
                    value: "\(counts.idle)",
                    outline: gridStyle ? Theme.idleOutline : nil,
                    dimmed: dimmed,
                    reducedOpacity: Theme.reducedOpacity(for: .idle)
                )
                LegendItem(
                    colour: Theme.drained,
                    label: "drained",
                    value: "\(counts.drained)",
                    dimmed: dimmed,
                    reducedOpacity: Theme.reducedOpacity(for: .drained)
                )
                LegendItem(
                    colour: Theme.down,
                    label: "down",
                    value: "\(counts.down)",
                    outline: gridStyle ? Theme.primaryText : nil,
                    dimmed: dimmed,
                    reducedOpacity: Theme.reducedOpacity(for: .down),
                    hollowWhenReduced: true
                )
                Spacer(minLength: 0)
            }
        }
    }
}

/// Medium: one stacked bar per partition, legend with totals as footer.
struct NodesMediumView: View {
    static let maxPartitions = 4

    let data: NodesData
    var isStale: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if shownPartitions.isEmpty {
                emptyMessage
            } else {
                rows
            }
            Spacer(minLength: 0)
            NodesLegendFooter(counts: data.stateCounts, dimmed: isStale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var shownPartitions: [PartitionNodes] {
        Array(data.partitions.prefix(NodesMediumView.maxPartitions))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shownPartitions) { (partition: PartitionNodes) in
                NodesPartitionRow(partition: partition, isStale: isStale)
            }
        }
        .padding(.top, 2)
    }

    private var emptyMessage: some View {
        Text("No partitions reported")
            .font(Theme.footerFont)
            .foregroundStyle(Theme.secondary(reduced: reduced))
    }
}

/// One partition: name, stacked bar, `148/170`, "2 down".
struct NodesPartitionRow: View {
    let partition: PartitionNodes
    var isStale: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(partition.name)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 44, alignment: .leading)
            StackedBar(segments: segments, dimmed: isStale)
            Text(partition.allocatedText)
                .font(Theme.footerValueFont)
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale, reduced: reduced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 54, alignment: .trailing)
            Text("\(partition.down) down")
                .font(Theme.labelFont)
                .foregroundStyle(downColour)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var segments: [BarSegment] {
        [
            segment(.allocated, count: partition.allocated),
            segment(.idle, count: partition.idle),
            segment(.drained, count: partition.drained),
            segment(.down, count: partition.down),
        ]
    }

    private func segment(_ state: NodeState, count: Int) -> BarSegment {
        BarSegment(
            weight: Double(count),
            colour: Theme.colour(for: state),
            reducedOpacity: Theme.reducedOpacity(for: state),
            hollowWhenReduced: Theme.isHollowWhenReduced(state),
            accent: state == .allocated
        )
    }

    /// Light red when more than one node is down.
    private var downColour: Color {
        if partition.down > 1 {
            return Theme.figure(Theme.down, dimmed: isStale, reduced: reduced)
        }
        return Theme.secondary(reduced: reduced)
    }
}
