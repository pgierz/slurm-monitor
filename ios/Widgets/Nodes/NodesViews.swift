import SlurmKit
import SwiftUI

// The small and medium nodes layouts and the legend they share with the
// extra large one. Each draws the body below the header and takes the data
// and the stale flag as plain values.

/// Small: the ring with the allocated percentage, and a two-by-two legend.
struct NodesSmallView: View {
    static let ringDiameter: CGFloat = 76

    let data: NodesData
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ring
            legend
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var ring: some View {
        ZStack {
            NodesRing(counts: data.stateCounts, lineWidth: 9, dimmed: isStale)
            centre
        }
        .frame(width: NodesSmallView.ringDiameter, height: NodesSmallView.ringDiameter)
    }

    private var centre: some View {
        VStack(alignment: .center, spacing: 0) {
            Text(Format.percent(data.allocatedFraction))
                .font(Theme.figureFont(size: 17))
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("allocated")
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .frame(width: NodesSmallView.ringDiameter - 26)
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
        LegendItem(colour: Theme.colour(for: state), label: label, value: "\(count)", dimmed: isStale)
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
                LegendItem(colour: Theme.running, label: "allocated", value: "\(counts.allocated)", dimmed: dimmed)
                LegendItem(
                    colour: gridStyle ? Theme.track : Theme.idleSegment,
                    label: "idle",
                    value: "\(counts.idle)",
                    outline: gridStyle ? Theme.idleOutline : nil,
                    dimmed: dimmed
                )
                LegendItem(colour: Theme.drained, label: "drained", value: "\(counts.drained)", dimmed: dimmed)
                LegendItem(
                    colour: Theme.down,
                    label: "down",
                    value: "\(counts.down)",
                    outline: gridStyle ? Theme.primaryText : nil,
                    dimmed: dimmed
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
            .foregroundStyle(Theme.secondaryText)
    }
}

/// One partition: name, stacked bar, `148/170`, "2 down".
struct NodesPartitionRow: View {
    let partition: PartitionNodes
    var isStale: Bool = false

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
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale))
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
            BarSegment(weight: Double(partition.allocated), colour: Theme.colour(for: .allocated)),
            BarSegment(weight: Double(partition.idle), colour: Theme.colour(for: .idle)),
            BarSegment(weight: Double(partition.drained), colour: Theme.colour(for: .drained)),
            BarSegment(weight: Double(partition.down), colour: Theme.colour(for: .down)),
        ]
    }

    /// Light red when more than one node is down.
    private var downColour: Color {
        if partition.down > 1 {
            return Theme.figure(Theme.down, dimmed: isStale)
        }
        return Theme.secondaryText
    }
}
