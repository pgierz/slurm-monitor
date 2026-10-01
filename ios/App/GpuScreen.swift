import SlurmKit
import SwiftUI

/// The GPU section.
struct GpuScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var content: WidgetContent<GpuData>? = nil

    var body: some View {
        FamilyScaffold(
            title: "GPU",
            content: content,
            reload: { await load() },
            openSettings: { model.selection = .settings }
        ) { data, tone in
            GpuDetail(data: data, tone: tone)
        }
        .task(id: ReloadKey(revision: model.revision, partition: nil)) {
            await load()
        }
    }

    private func load() async {
        let result = await model.makeLoader().gpu()
        if Task.isCancelled { return }
        content = result
    }
}

/// The GPU content for one snapshot.
struct GpuDetail: View {
    let data: GpuData
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            totalsPanel
            typesPanel
            ForEach(data.typeGroups) { group in
                GpuGroupPanel(group: group, metricsAvailable: data.metricsAvailable, tone: tone)
            }
            topUsersPanel
            historyPanel
        }
    }

    // MARK: Totals

    private var totalsPanel: some View {
        Panel("GPU cards") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(data.allocated)")
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .foregroundStyle(tone.blue)
                Text("/ \(data.total)")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                Text("allocated")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(data.allocated) of \(data.total) GPU cards allocated")

            if data.showsIdleAllocated {
                Text("\(data.idleAllocated ?? 0) allocated but idle")
                    .font(.subheadline)
                    .foregroundStyle(tone.amber)
            }
            if !data.metricsAvailable {
                NoteText("Per-card metrics are not connected; only allocation is shown.")
            }
            Hairline()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 12) {
                FigureView(value: "\(data.pendingJobs)", label: "jobs pending", colour: tone.amber, large: false)
                FigureView(value: longestWaitText, label: "longest wait", colour: tone.primary, large: false)
            }
        }
    }

    private var longestWaitText: String {
        if data.pendingJobs == 0 {
            return Format.dash
        }
        return Format.durationWords(seconds: data.longestWaitSeconds)
    }

    // MARK: Types

    private var typesPanel: some View {
        Panel("By card type") {
            if data.types.isEmpty {
                NoteText("The server reported no GPU type.")
            } else {
                ForEach(data.types) { type in
                    GpuTypeRow(type: type, tone: tone)
                }
            }
        }
    }

    // MARK: Top users

    private var topUsersPanel: some View {
        Panel("Top users · cards") {
            if data.topUsers.isEmpty {
                NoteText("No card is allocated.")
            } else {
                ForEach(data.topUsers) { entry in
                    HStack {
                        Text(entry.user)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Palette.primary)
                        Spacer(minLength: 8)
                        Text("\(entry.cards)")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(tone.primary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.user): \(entry.cards) cards")
                }
            }
        }
    }

    // MARK: History

    private var historyPanel: some View {
        Panel(data.metricsAvailable ? "Allocation and utilisation, last hours" : "Allocation, last hours") {
            if data.history.count < 2 {
                NoteText("No history yet.")
            } else {
                HistoryChart(
                    samples: historySamples,
                    seriesNames: historySeriesNames,
                    seriesColours: historySeriesColours,
                    summary: historySummary
                )
                NoteText("Per cent of all cards allocated" + (data.metricsAvailable ? "; mean utilisation of the allocated cards." : "."))
            }
        }
    }

    private var historySeriesNames: [String] {
        data.metricsAvailable ? ["Allocated", "Utilisation"] : ["Allocated"]
    }

    private var historySeriesColours: [Color] {
        data.metricsAvailable ? [tone.blue, tone.primary] : [tone.blue]
    }

    private var historySamples: [HistorySample] {
        var samples: [HistorySample] = []
        for (index, point) in data.history.enumerated() {
            samples.append(HistorySample(id: index * 2, time: point.t, value: point.allocatedFraction * 100, series: "Allocated"))
            if data.metricsAvailable, let utilisation = point.utilisation {
                samples.append(HistorySample(id: index * 2 + 1, time: point.t, value: utilisation * 100, series: "Utilisation"))
            }
        }
        return samples
    }

    private var historySummary: String {
        guard let first = data.history.first, let last = data.history.last else {
            return "GPU history: no data"
        }
        let start = Format.clockTime(first.t, timeZone: .current)
        let end = Format.clockTime(last.t, timeZone: .current)
        var text = "GPU history from \(start) to \(end). Allocated went from \(Format.percent(first.allocatedFraction)) to \(Format.percent(last.allocatedFraction))."
        if data.metricsAvailable, let utilisation = last.utilisation {
            text += " Utilisation is now \(Format.percent(utilisation))."
        }
        return text
    }
}

private struct GpuTypeRow: View {
    let type: GpuTypeCount
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(type.label)
                    .font(.subheadline)
                    .foregroundStyle(Palette.primary)
                Spacer(minLength: 8)
                Text(type.allocatedText)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(tone.primary)
            }
            MeterBar(fraction: type.allocatedFraction, colour: tone.blue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(type.label): \(type.allocated) of \(type.total) cards allocated")
    }
}

private struct GpuGroupPanel: View {
    let group: GpuTypeGroup
    let metricsAvailable: Bool
    let tone: Tone

    @ScaledMetric(relativeTo: .footnote) private var cardWidth: CGFloat = 112

    var body: some View {
        Panel(group.heading, trailing: group.type.allocatedText) {
            if group.nodes.isEmpty {
                NoteText("No node listed.")
            } else {
                ForEach(group.nodes) { node in
                    nodeBlock(node)
                }
                GpuLegend(metricsAvailable: metricsAvailable, tone: tone)
            }
        }
    }

    private func nodeBlock(_ node: GpuNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node.name)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(Palette.primary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth), spacing: 8, alignment: .topLeading)], alignment: .leading, spacing: 8) {
                ForEach(node.cards) { card in
                    GpuCardCell(card: card, nodeName: node.name, metricsAvailable: metricsAvailable, tone: tone)
                }
            }
        }
    }
}

private struct GpuCardCell: View {
    let card: GpuCard
    let nodeName: String
    let metricsAvailable: Bool
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(card.index)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                Spacer(minLength: 4)
                Text(Format.cardText(card))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(textColour)
            }
            if showsMetrics {
                Text(memoryText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                Text(Format.temperature(celsius: card.temperatureC) + " · " + Format.power(watts: card.powerW))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
            }
            if card.state.isAllocated {
                Text(card.user ?? Format.dash)
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            if showsMetrics, let fraction = card.memoryFraction {
                MeterBar(fraction: fraction, colour: outlineColour, height: 3)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fillColour)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(outlineColour, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var showsMetrics: Bool {
        metricsAvailable && card.state.isAllocated
    }

    private var memoryText: String {
        Format.memoryGigabytes(mib: card.memoryUsedMib) + " / " + Format.memoryGigabytes(mib: card.memoryTotalMib)
    }

    private var fillColour: Color {
        if tone.stale {
            return Color.clear
        }
        switch card.state {
        case .busy, .allocated: return Palette.busyCardFill
        case .idleAllocated: return Palette.idleCardFill
        case .free, .drained, .down, .unknown: return Color.clear
        }
    }

    private var outlineColour: Color {
        switch card.state {
        case .busy, .allocated: return tone.blue
        case .idleAllocated: return tone.amber
        case .free, .unknown: return Palette.trackOutline
        case .drained: return tone.drained
        case .down: return tone.down
        }
    }

    private var textColour: Color {
        switch card.state {
        case .busy, .allocated: return tone.primary
        case .idleAllocated: return tone.amber
        case .free, .unknown: return Palette.secondary
        case .drained: return tone.drained
        case .down: return tone.down
        }
    }

    private var stateWords: String {
        switch card.state {
        case .busy: return "busy"
        case .idleAllocated: return "allocated but idle"
        case .allocated: return "allocated"
        case .free: return "free"
        case .drained: return "drained"
        case .down: return "down"
        case .unknown: return "state not known"
        }
    }

    private var accessibilityText: String {
        var text = "\(nodeName), card \(card.index), \(stateWords)"
        if card.state.isAllocated, let user = card.user {
            text += ", used by \(user)"
        }
        if showsMetrics {
            if let utilisation = card.utilisation {
                text += ", utilisation \(Format.percent(utilisation))"
            }
            if let used = card.memoryUsedMib, let total = card.memoryTotalMib {
                text += ", memory \(Format.memoryGigabytes(mib: used)) of \(Format.memoryGigabytes(mib: total))"
            }
            if let temperature = card.temperatureC {
                text += ", \(Int(temperature.rounded())) degrees"
            }
            if let power = card.powerW {
                text += ", \(Int(power.rounded())) watts"
            }
        }
        return text
    }
}

private struct GpuLegend: View {
    let metricsAvailable: Bool
    let tone: Tone

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
            LegendItem(colour: tone.blue, text: metricsAvailable ? "busy" : "allocated")
            if metricsAvailable {
                LegendItem(colour: tone.amber, text: "allocated, idle")
            }
            LegendItem(colour: Palette.trackOutline, text: "free", outlined: true)
            LegendItem(colour: tone.drained, text: "drained", outlined: true)
            LegendItem(colour: tone.down, text: "down", outlined: true)
        }
        .accessibilityHidden(true)
    }
}

#Preview("GPU") {
    ScrollView {
        GpuDetail(data: SampleData.gpu.data, tone: Tone(stale: false))
            .padding()
    }
    .background(Palette.background)
    .preferredColorScheme(.dark)
}

#Preview("GPU, no metrics") {
    ScrollView {
        GpuDetail(data: SampleData.gpuNoMetrics.data, tone: Tone(stale: false))
            .padding()
    }
    .background(Palette.background)
    .preferredColorScheme(.dark)
}
