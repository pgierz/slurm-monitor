import SlurmKit
import SwiftUI

/// The Nodes section: loads the snapshot and offers the partition filter.
struct NodesScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var content: WidgetContent<NodesData>? = nil
    @State private var partition: String?

    init(initialPartition: String?) {
        _partition = State(initialValue: initialPartition)
    }

    var body: some View {
        FamilyScaffold(
            title: "Nodes",
            content: content,
            reload: { await load() },
            openSettings: { model.selection = .settings }
        ) { data, tone in
            NodesDetail(data: data, tone: tone)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PartitionMenu(selection: $partition, names: model.partitionChoices(including: partition))
            }
        }
        .task(id: ReloadKey(revision: model.revision, partition: partition)) {
            await load()
        }
    }

    private func load() async {
        let asked = partition
        let result = await model.makeLoader().nodes(partition: asked)
        if Task.isCancelled { return }
        content = result
        if asked == nil, let nodes = result.value {
            model.notePartitions(nodes)
        } else if result.value != nil {
            await model.learnPartitionsIfNeeded()
        }
    }
}

/// How node states are drawn and named.
enum NodeStateStyle {
    static func word(_ state: NodeState) -> String {
        switch state {
        case .allocated: return "allocated"
        case .idle: return "idle"
        case .drained: return "drained"
        case .down: return "down"
        case .unknown: return "state not known"
        }
    }

    static func fill(_ state: NodeState, tone: Tone) -> Color {
        switch state {
        case .allocated: return tone.blue
        case .idle: return Palette.track
        case .drained: return tone.drained
        case .down: return tone.down
        case .unknown: return Color.clear
        }
    }

    static func outline(_ state: NodeState, tone: Tone) -> Color {
        switch state {
        case .allocated: return tone.blue
        case .idle: return Palette.trackOutline
        case .drained: return tone.drained
        case .down: return Color.white
        case .unknown: return Palette.trackOutline
        }
    }

    static func segments(_ counts: NodeStateCounts, tone: Tone) -> [BarSegment] {
        let fractions = counts.fractions
        let colours = [tone.blue, tone.idle, tone.drained, tone.down]
        var segments: [BarSegment] = []
        for index in 0..<min(fractions.count, colours.count) {
            segments.append(BarSegment(id: index, fraction: fractions[index], colour: colours[index]))
        }
        return segments
    }
}

/// The node the user tapped in a grid.
struct SelectedNode: Equatable {
    var partition: String
    var name: String
    var state: NodeState
}

/// The Nodes content for one snapshot.
struct NodesDetail: View {
    let data: NodesData
    let tone: Tone

    @State private var selected: SelectedNode? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            totalsPanel
            partitionsPanel
            ForEach(data.partitions) { partition in
                NodeGridPanel(partition: partition, tone: tone, selected: $selected)
            }
        }
    }

    private var totalsPanel: some View {
        Panel("Nodes · \(data.total)", trailing: Format.percent(data.allocatedFraction) + " allocated") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 12) {
                FigureView(value: "\(data.allocated)", label: "allocated", colour: tone.blue, large: false)
                FigureView(value: "\(data.idle)", label: "idle", colour: tone.primary, large: false)
                FigureView(value: "\(data.drained)", label: "drained", colour: tone.drained, large: false)
                FigureView(value: "\(data.down)", label: "down", colour: tone.down, large: false)
            }
            StackedBar(segments: NodeStateStyle.segments(data.stateCounts, tone: tone))
            NodeLegend(tone: tone)
        }
    }

    private var partitionsPanel: some View {
        Panel("By partition") {
            if data.partitions.isEmpty {
                NoteText("The server reported no partition.")
            } else {
                ForEach(data.partitions) { partition in
                    PartitionBarRow(partition: partition, tone: tone)
                }
            }
        }
    }
}

private struct NodeLegend: View {
    let tone: Tone

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
            LegendItem(colour: tone.blue, text: "allocated")
            LegendItem(colour: Palette.trackOutline, text: "idle", outlined: true)
            LegendItem(colour: tone.drained, text: "drained")
            LegendItem(colour: tone.down, text: "down")
        }
        .accessibilityHidden(true)
    }
}

private struct PartitionBarRow: View {
    let partition: PartitionNodes
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(partition.name)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Palette.primary)
                Spacer(minLength: 8)
                if partition.down > 0 {
                    Text("\(partition.down) down")
                        .font(.footnote)
                        .foregroundStyle(partition.down > 1 ? tone.down : Palette.secondary)
                }
                Text(partition.allocatedText)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(tone.primary)
            }
            StackedBar(segments: NodeStateStyle.segments(partition.stateCounts, tone: tone))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Partition \(partition.name): \(partition.allocated) of \(partition.total) allocated, \(partition.idle) idle, \(partition.drained) drained, \(partition.down) down")
    }
}

private struct NodeGridPanel: View {
    let partition: PartitionNodes
    let tone: Tone
    @Binding var selected: SelectedNode?

    @ScaledMetric(relativeTo: .body) private var cellSize: CGFloat = 20

    var body: some View {
        Panel(partition.name, trailing: partition.allocatedText) {
            if partition.nodes.isEmpty {
                NoteText("No node listed.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize, maximum: cellSize), spacing: 5)], alignment: .leading, spacing: 5) {
                    ForEach(partition.nodes) { node in
                        NodeCell(node: node, tone: tone, size: cellSize, isSelected: isSelected(node)) {
                            select(node)
                        }
                    }
                }
                selectionLine
            }
        }
    }

    @ViewBuilder
    private var selectionLine: some View {
        if let selected = selected, selected.partition == partition.name {
            HStack(spacing: 8) {
                Text(selected.name)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Palette.primary)
                Text(NodeStateStyle.word(selected.state))
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            NoteText("Tap a cell to see the node's name and state.")
        }
    }

    private func isSelected(_ node: NodeInfo) -> Bool {
        guard let selected = selected else { return false }
        return selected.partition == partition.name && selected.name == node.name
    }

    private func select(_ node: NodeInfo) {
        if isSelected(node) {
            selected = nil
        } else {
            selected = SelectedNode(partition: partition.name, name: node.name, state: node.state)
        }
    }
}

private struct NodeCell: View {
    let node: NodeInfo
    let tone: Tone
    let size: CGFloat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(NodeStateStyle.fill(node.state, tone: tone))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(outlineColour, lineWidth: isSelected ? 2.5 : 1)
                )
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(node.name), \(NodeStateStyle.word(node.state))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var outlineColour: Color {
        if isSelected {
            return Palette.amber
        }
        return NodeStateStyle.outline(node.state, tone: tone)
    }
}

#Preview("Nodes") {
    ScrollView {
        NodesDetail(data: SampleData.nodes.data, tone: Tone(stale: false))
            .padding()
    }
    .background(Palette.background)
    .preferredColorScheme(.dark)
}
