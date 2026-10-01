import SlurmKit
import SwiftUI
import WidgetKit

/// One partition of the node grid: the nodes that are drawn and the rows
/// they take.
struct NodesGridBlock: Identifiable {
    let partition: PartitionNodes
    let shownNodes: [NodeInfo]
    let rows: Int

    var id: String { partition.name }
}

/// How the node grid is laid out in a given area: the cell size, the columns
/// and what is drawn of each partition.
///
/// The cell is the largest of 20, 16, 14, 12, 10, 8 and 6 pt with which all
/// blocks fit the height, so that a small cluster fills the area and a large
/// one still shows every node. If even 6 pt does not fit, the rows that fit
/// are drawn and the rest is counted in `hiddenNodes` ("and N more").
struct NodesGridPlan {
    static let cellSizes: [CGFloat] = [20, 16, 14, 12, 10, 8, 6]
    /// Between partition blocks.
    static let blockSpacing: CGFloat = 8
    /// Height of the partition label; a block is never lower.
    static let minimumBlockHeight: CGFloat = 14
    /// Height kept free for the "and N more" note.
    static let noteHeight: CGFloat = 14

    let cellSize: CGFloat
    let gap: CGFloat
    let columns: Int
    let blocks: [NodesGridBlock]
    let hiddenNodes: Int

    /// Distance from one cell to the next.
    var pitch: CGFloat { cellSize + gap }

    func height(of block: NodesGridBlock) -> CGFloat {
        NodesGridPlan.blockHeight(rows: block.rows, cellSize: cellSize)
    }

    static func gap(for cellSize: CGFloat) -> CGFloat {
        if cellSize > 14 {
            return 4
        }
        return cellSize >= 10 ? 3 : 2
    }

    static func columns(width: CGFloat, cellSize: CGFloat) -> Int {
        let gap: CGFloat = NodesGridPlan.gap(for: cellSize)
        return max(1, Int((width + gap) / (cellSize + gap)))
    }

    static func rows(count: Int, columns: Int) -> Int {
        if count <= 0 || columns <= 0 {
            return 0
        }
        return (count + columns - 1) / columns
    }

    static func blockHeight(rows: Int, cellSize: CGFloat) -> CGFloat {
        let gap: CGFloat = NodesGridPlan.gap(for: cellSize)
        let cells: CGFloat = CGFloat(rows) * (cellSize + gap) - gap
        return max(minimumBlockHeight, cells)
    }

    /// Height of all blocks with every node drawn.
    static func fullHeight(partitions: [PartitionNodes], width: CGFloat, cellSize: CGFloat) -> CGFloat {
        let columns: Int = NodesGridPlan.columns(width: width, cellSize: cellSize)
        var total: CGFloat = 0
        for partition in partitions {
            let rows: Int = NodesGridPlan.rows(count: partition.nodes.count, columns: columns)
            total += blockHeight(rows: rows, cellSize: cellSize)
        }
        if partitions.count > 1 {
            total += blockSpacing * CGFloat(partitions.count - 1)
        }
        return total
    }

    static func make(partitions: [PartitionNodes], width: CGFloat, height: CGFloat) -> NodesGridPlan {
        for cellSize in cellSizes {
            let needed: CGFloat = fullHeight(partitions: partitions, width: width, cellSize: cellSize)
            if needed <= height {
                return complete(partitions: partitions, width: width, cellSize: cellSize)
            }
        }
        return capped(partitions: partitions, width: width, height: height)
    }

    /// Every node drawn at the given cell size.
    private static func complete(partitions: [PartitionNodes], width: CGFloat, cellSize: CGFloat) -> NodesGridPlan {
        let columns: Int = NodesGridPlan.columns(width: width, cellSize: cellSize)
        var blocks: [NodesGridBlock] = []
        for partition in partitions {
            let rows: Int = NodesGridPlan.rows(count: partition.nodes.count, columns: columns)
            blocks.append(NodesGridBlock(partition: partition, shownNodes: partition.nodes, rows: rows))
        }
        return NodesGridPlan(
            cellSize: cellSize,
            gap: NodesGridPlan.gap(for: cellSize),
            columns: columns,
            blocks: blocks,
            hiddenNodes: 0
        )
    }

    /// The last resort: the smallest cell, and only the rows that fit.
    private static func capped(partitions: [PartitionNodes], width: CGFloat, height: CGFloat) -> NodesGridPlan {
        let cellSize: CGFloat = cellSizes[cellSizes.count - 1]
        let gap: CGFloat = NodesGridPlan.gap(for: cellSize)
        let pitch: CGFloat = cellSize + gap
        let columns: Int = NodesGridPlan.columns(width: width, cellSize: cellSize)
        var remaining: CGFloat = height - noteHeight - blockSpacing
        var blocks: [NodesGridBlock] = []
        var hidden: Int = 0

        for partition in partitions {
            let count: Int = partition.nodes.count
            if remaining < minimumBlockHeight {
                hidden += count
                continue
            }
            let neededRows: Int = NodesGridPlan.rows(count: count, columns: columns)
            let fittingRows: Int = max(1, Int((remaining + gap) / pitch))
            let rows: Int = min(neededRows, fittingRows)
            let shown: [NodeInfo] = Array(partition.nodes.prefix(rows * columns))
            hidden += count - shown.count
            blocks.append(NodesGridBlock(partition: partition, shownNodes: shown, rows: rows))
            remaining -= blockHeight(rows: rows, cellSize: cellSize) + blockSpacing
        }

        return NodesGridPlan(cellSize: cellSize, gap: gap, columns: columns, blocks: blocks, hiddenNodes: hidden)
    }
}

/// The cells of one partition, one rounded square per node, coloured by state.
struct NodesCellGrid: View {
    let nodes: [NodeInfo]
    let columns: Int
    let cellSize: CGFloat
    let gap: CGFloat
    var dimmed: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        // Read here, not inside the drawing closure.
        let reducedStyle: Bool = reduced
        return Canvas { context, size in
            let perRow: Int = max(1, columns)
            let pitch: CGFloat = cellSize + gap
            for index in 0..<nodes.count {
                let column: Int = index % perRow
                let row: Int = index / perRow
                let rect = CGRect(
                    x: CGFloat(column) * pitch,
                    y: CGFloat(row) * pitch,
                    width: cellSize,
                    height: cellSize
                )
                if reducedStyle {
                    drawReducedCell(nodes[index].state, in: rect, context: context)
                } else {
                    drawCell(nodes[index].state, in: rect, context: context)
                }
            }
        }
        .widgetAccentable()
    }

    private func drawCell(_ state: NodeState, in rect: CGRect, context: GraphicsContext) {
        let radius: CGFloat = cellSize / 4
        let path = Path(roundedRect: rect, cornerRadius: radius)
        context.fill(path, with: .color(fillColour(state)))
        if let outline = outlineColour(state) {
            let inset: CGRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let outlinePath = Path(roundedRect: inset, cornerRadius: max(0, radius - 0.5))
            context.stroke(outlinePath, with: .color(outline), lineWidth: 1)
        }
    }

    /// Reduced colour: one colour, the state in its opacity (allocated 1.0,
    /// idle 0.25, drained 0.5); a down node is a hollow cell at 1.0.
    private func drawReducedCell(_ state: NodeState, in rect: CGRect, context: GraphicsContext) {
        let radius: CGFloat = cellSize / 4
        let colour: Color = Theme.reducedColour(for: state, dimmed: dimmed)
        if Theme.isHollowWhenReduced(state) {
            let lineWidth: CGFloat = cellSize >= 10 ? 1.5 : 1
            let inset: CGRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let outlinePath = Path(roundedRect: inset, cornerRadius: max(0, radius - lineWidth / 2))
            context.stroke(outlinePath, with: .color(colour), lineWidth: lineWidth)
        } else {
            let path = Path(roundedRect: rect, cornerRadius: radius)
            context.fill(path, with: .color(colour))
        }
    }

    private func fillColour(_ state: NodeState) -> Color {
        switch state {
        case .allocated:
            return Theme.figure(Theme.running, dimmed: dimmed)
        case .idle, .unknown:
            return Theme.track
        case .drained:
            return dimmed ? Theme.staleFigure.opacity(0.5) : Theme.drained
        case .down:
            return dimmed ? Theme.staleFigure.opacity(0.25) : Theme.down
        }
    }

    private func outlineColour(_ state: NodeState) -> Color? {
        switch state {
        case .idle, .unknown:
            return Theme.idleOutline
        case .down:
            return Theme.primaryText
        case .allocated, .drained:
            return nil
        }
    }
}

/// Extra large (iPad): one block per partition with a cell per node, legend
/// with totals as footer.
struct NodesExtraLargeView: View {
    static let labelWidth: CGFloat = 104
    static let labelGap: CGFloat = 12

    let data: NodesData
    var isStale: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { (proxy: GeometryProxy) in
                gridArea(size: proxy.size)
            }
            NodesLegendFooter(counts: data.stateCounts, gridStyle: true, dimmed: isStale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func gridWidth(_ total: CGFloat) -> CGFloat {
        max(0, total - NodesExtraLargeView.labelWidth - NodesExtraLargeView.labelGap)
    }

    private func gridArea(size: CGSize) -> some View {
        let width: CGFloat = gridWidth(size.width)
        let plan: NodesGridPlan = NodesGridPlan.make(partitions: data.partitions, width: width, height: size.height)
        return VStack(alignment: .leading, spacing: NodesGridPlan.blockSpacing) {
            ForEach(plan.blocks) { (block: NodesGridBlock) in
                NodesGridBlockRow(block: block, plan: plan, gridWidth: width, isStale: isStale)
            }
            if plan.hiddenNodes > 0 {
                Text("and \(plan.hiddenNodes) more")
                    .font(Theme.footerFont)
                    .foregroundStyle(Theme.secondary(reduced: reduced))
                    .lineLimit(1)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// One partition block: name and `148/170` on the left, then the cells.
struct NodesGridBlockRow: View {
    let block: NodesGridBlock
    let plan: NodesGridPlan
    let gridWidth: CGFloat
    var isStale: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        HStack(alignment: .top, spacing: NodesExtraLargeView.labelGap) {
            label
                .frame(width: NodesExtraLargeView.labelWidth, alignment: .leading)
            NodesCellGrid(
                nodes: block.shownNodes,
                columns: plan.columns,
                cellSize: plan.cellSize,
                gap: plan.gap,
                dimmed: isStale
            )
            .frame(width: gridWidth, height: plan.height(of: block), alignment: .topLeading)
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(block.partition.name)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            Text(block.partition.allocatedText)
                .font(Theme.footerValueFont)
                .foregroundStyle(Theme.figure(Theme.secondaryText, dimmed: isStale, reduced: reduced))
                .lineLimit(1)
                .fixedSize()
        }
    }
}
