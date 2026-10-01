import SlurmKit
import SwiftUI

/// Measures of the node grid for one widget size.
struct GpuGridMetrics {
    /// Cell width when the cards of a node fit at full size.
    let preferredCellWidth: CGFloat
    /// True for the wide cells of the extra large layout.
    let showsDetail: Bool
    /// Between headings, node rows and the "more" line.
    let rowSpacing: CGFloat
    let cellSpacing: CGFloat = 4
    let nameWidth: CGFloat = 50
    let nameGap: CGFloat = 6
    let headingHeight: CGFloat = 13
    let moreLineHeight: CGFloat = 13
    let minimumCellWidth: CGFloat = 12

    static let large = GpuGridMetrics(preferredCellWidth: GpuCardMetrics.compactWidth, showsDetail: false, rowSpacing: 3)
    static let extraLarge = GpuGridMetrics(preferredCellWidth: GpuCardMetrics.wideWidth, showsDetail: true, rowSpacing: 3)

    /// The cell width for nodes with `cards` cards in a grid `available`
    /// points wide: the preferred width, or less when the row would not fit.
    func cellWidth(cards: Int, available: CGFloat) -> CGFloat {
        let count: Int = max(1, cards)
        let gaps: CGFloat = CGFloat(count - 1) * cellSpacing
        let space: CGFloat = available - nameWidth - nameGap - gaps
        let fitting: CGFloat = (space / CGFloat(count)).rounded(.down)
        return max(minimumCellWidth, min(preferredCellWidth, fitting))
    }

    /// Width of a node row: name, gap and cells.
    func rowWidth(cards: Int, cellWidth: CGFloat) -> CGFloat {
        let count: Int = max(1, cards)
        return nameWidth + nameGap + CGFloat(count) * cellWidth + CGFloat(count - 1) * cellSpacing
    }
}

/// The nodes of one type that are shown.
struct GpuGridSection: Identifiable {
    let group: GpuTypeGroup
    let nodes: [GpuNode]

    var id: String { group.id }
}

/// Which node rows the grid shows and how many are left out.
struct GpuGridPlan {
    let sections: [GpuGridSection]
    let hiddenNodes: Int

    var rowCount: Int {
        var count: Int = 0
        for section in sections {
            count += section.nodes.count
        }
        return count
    }

    /// The first `rowLimit` nodes, in group order. Groups without a shown node get no heading.
    static func make(groups: [GpuTypeGroup], rowLimit: Int) -> GpuGridPlan {
        var sections: [GpuGridSection] = []
        var remaining: Int = max(0, rowLimit)
        var hidden: Int = 0
        for group in groups {
            let shown: [GpuNode] = Array(group.nodes.prefix(remaining))
            remaining -= shown.count
            hidden += group.nodes.count - shown.count
            if !shown.isEmpty {
                sections.append(GpuGridSection(group: group, nodes: shown))
            }
        }
        return GpuGridPlan(sections: sections, hiddenNodes: hidden)
    }

    /// Height of the grid as `GpuNodeGrid` draws it.
    func height(metrics: GpuGridMetrics) -> CGFloat {
        let rows: Int = rowCount
        let moreLines: Int = hiddenNodes > 0 ? 1 : 0
        let items: Int = sections.count + rows + moreLines
        if items == 0 {
            return 0
        }
        let headings: CGFloat = CGFloat(sections.count) * metrics.headingHeight
        let cells: CGFloat = CGFloat(rows) * GpuCardMetrics.height
        let more: CGFloat = CGFloat(moreLines) * metrics.moreLineHeight
        let gaps: CGFloat = CGFloat(items - 1) * metrics.rowSpacing
        return headings + cells + more + gaps
    }

    /// The plan with the most rows, up to `maxRows`, that fits into `height`.
    /// At least one row is kept, however small the space.
    static func fitting(groups: [GpuTypeGroup], maxRows: Int, height: CGFloat, metrics: GpuGridMetrics) -> GpuGridPlan {
        var limit: Int = max(1, maxRows)
        while limit > 1 {
            let plan: GpuGridPlan = make(groups: groups, rowLimit: limit)
            if plan.height(metrics: metrics) <= height + 0.5 {
                return plan
            }
            limit -= 1
        }
        return make(groups: groups, rowLimit: 1)
    }
}

/// The grid: per type a heading, then one row per node with one cell per card.
struct GpuNodeGrid: View {
    let plan: GpuGridPlan
    /// Width available to the grid.
    let width: CGFloat
    let metrics: GpuGridMetrics
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            ForEach(plan.sections) { (section: GpuGridSection) in
                GpuGridSectionView(section: section, width: width, metrics: metrics, isStale: isStale)
            }
            if plan.hiddenNodes > 0 {
                moreLine
            }
        }
    }

    private var moreText: String {
        let count: Int = plan.hiddenNodes
        return count == 1 ? "and 1 more node" : "and \(count) more nodes"
    }

    private var moreLine: some View {
        Text(moreText)
            .font(Theme.labelFont)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .frame(height: metrics.moreLineHeight)
    }
}

/// Heading and node rows of one card type.
struct GpuGridSectionView: View {
    let section: GpuGridSection
    let width: CGFloat
    let metrics: GpuGridMetrics
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            heading
            ForEach(section.nodes) { (node: GpuNode) in
                GpuNodeRow(node: node, cellWidth: cellWidth, metrics: metrics, isStale: isStale)
            }
        }
    }

    private var cardsPerNode: Int {
        section.group.cardsPerNode
    }

    private var cellWidth: CGFloat {
        metrics.cellWidth(cards: cardsPerNode, available: width)
    }

    private var headingWidth: CGFloat {
        let row: CGFloat = metrics.rowWidth(cards: cardsPerNode, cellWidth: cellWidth)
        return max(0, min(width, row))
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.group.heading)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(section.group.type.allocatedText)
                .font(Theme.figureFont(size: 10, weight: .medium))
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale))
                .lineLimit(1)
        }
        .frame(width: headingWidth, height: metrics.headingHeight)
    }
}

/// One node: its name, then one cell per card.
struct GpuNodeRow: View {
    let node: GpuNode
    let cellWidth: CGFloat
    let metrics: GpuGridMetrics
    var isStale: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: metrics.nameGap) {
            name
            cells
        }
        .frame(height: GpuCardMetrics.height)
    }

    private var nameColour: Color {
        switch node.state {
        case .allocated, .idle, .unknown:
            return Theme.figure(Theme.primaryText, dimmed: isStale)
        case .drained, .down:
            return Theme.figure(Theme.secondaryText, dimmed: isStale)
        }
    }

    private var name: some View {
        Text(node.name)
            .font(Theme.figureFont(size: 10, weight: .medium))
            .foregroundStyle(nameColour)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .truncationMode(.middle)
            .frame(width: metrics.nameWidth, alignment: .leading)
    }

    private var cells: some View {
        HStack(alignment: .center, spacing: metrics.cellSpacing) {
            ForEach(node.cards) { (card: GpuCard) in
                GpuCardCell(card: card, width: cellWidth, showsDetail: metrics.showsDetail, isStale: isStale)
            }
        }
    }
}

/// One entry of the card legend.
struct GpuLegendEntry {
    let label: String
    let fill: Color
    let outline: Color
}

/// The legend of the card states. Without metrics, busy and idle are
/// replaced by "allocated", as the cells then show only that.
struct GpuLegend: View {
    let metricsAvailable: Bool
    /// Entries per line; the extra large side column uses two.
    var perLine: Int = 5
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<lines.count, id: \.self) { (index: Int) in
                line(lines[index])
            }
        }
    }

    private var entries: [GpuLegendEntry] {
        var result: [GpuLegendEntry] = []
        if metricsAvailable {
            result.append(GpuLegendEntry(label: "busy", fill: Theme.gpuBusyFill, outline: Theme.running))
            result.append(GpuLegendEntry(label: "idle", fill: Theme.gpuIdleAllocatedFill, outline: Theme.pending))
        } else {
            result.append(GpuLegendEntry(label: "allocated", fill: Theme.gpuBusyFill, outline: Theme.running))
        }
        result.append(GpuLegendEntry(label: "free", fill: Color.clear, outline: Theme.idleOutline))
        result.append(GpuLegendEntry(label: "drained", fill: Color.clear, outline: Theme.drained))
        result.append(GpuLegendEntry(label: "down", fill: Color.clear, outline: Theme.down))
        return result
    }

    private var lines: [[GpuLegendEntry]] {
        let all: [GpuLegendEntry] = entries
        let step: Int = max(1, perLine)
        var result: [[GpuLegendEntry]] = []
        var start: Int = 0
        while start < all.count {
            let end: Int = min(all.count, start + step)
            result.append(Array(all[start..<end]))
            start = end
        }
        return result
    }

    private func line(_ items: [GpuLegendEntry]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(0..<items.count, id: \.self) { (index: Int) in
                LegendItem(
                    colour: isStale ? Color.clear : items[index].fill,
                    label: items[index].label,
                    outline: isStale ? Theme.staleFigure : items[index].outline
                )
            }
        }
    }
}
