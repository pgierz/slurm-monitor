import SlurmKit
import SwiftUI

// The four GPU layouts. Each draws the body below the header and takes the
// data and the stale flag as plain values.

/// Small: allocated of total, the idle line, footer with the first two types.
struct GpuSmallView: View {
    static let maxTypes = 2

    let data: GpuData
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            figure
            idleLine
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var figure: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(data.allocated)")
                .font(Theme.figureFont(size: 32))
                .foregroundStyle(Theme.figure(Theme.running, dimmed: isStale))
            Text("/ \(data.total)")
                .font(Theme.figureFont(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private var idleLine: some View {
        if data.showsIdleAllocated {
            Text("\(data.idleAllocated ?? 0) allocated but idle")
                .font(Theme.footerFont)
                .foregroundStyle(Theme.figure(Theme.pending, dimmed: isStale))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 2)
        }
    }

    private var shownTypes: [GpuTypeCount] {
        Array(data.types.prefix(GpuSmallView.maxTypes))
    }

    @ViewBuilder
    private var footer: some View {
        if !shownTypes.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.footerGap) {
                Hairline()
                typeLine
            }
        }
    }

    private var typeLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            typeText(shownTypes[0])
            Spacer(minLength: 4)
            if shownTypes.count > 1 {
                typeText(shownTypes[1])
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func typeText(_ type: GpuTypeCount) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(type.label)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.secondaryText)
            Text(type.allocatedText)
                .font(Theme.footerValueFont)
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale))
        }
    }
}

/// Medium: bars per type and three figures on the left, the sparkline on the right.
struct GpuMediumView: View {
    static let maxTypes = 3
    static let sparklineWidth: CGFloat = 118

    let data: GpuData
    var isStale: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.column) {
            leftColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            sparklineColumn
                .frame(width: GpuMediumView.sparklineWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            typeBars
            Spacer(minLength: 6)
            figures
        }
    }

    private var shownTypes: [GpuTypeCount] {
        Array(data.types.prefix(GpuMediumView.maxTypes))
    }

    private var typeBars: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shownTypes) { (type: GpuTypeCount) in
                LabelledBar(
                    label: type.label,
                    fraction: type.allocatedFraction,
                    value: type.allocatedText,
                    colour: Theme.running,
                    labelWidth: 40,
                    valueWidth: 40,
                    dimmed: isStale
                )
            }
        }
    }

    /// The longest wait; a dash when nothing is pending (the server then
    /// sends 0) or it is unknown.
    private var longestWaitText: String {
        if data.pendingJobs <= 0 {
            return Format.dash
        }
        return Format.durationWords(seconds: data.longestWaitSeconds)
    }

    /// The idle-allocated count; a dash without metrics.
    private var idleText: String {
        guard data.metricsAvailable, let idle = data.idleAllocated else {
            return Format.dash
        }
        return "\(idle)"
    }

    private var figures: some View {
        HStack(alignment: .top, spacing: 12) {
            FigureView(value: "\(data.pendingJobs)", label: "pending", colour: Theme.pending, size: .small, dimmed: isStale)
            FigureView(value: longestWaitText, label: "longest wait", colour: Theme.primaryText, size: .small, dimmed: isStale)
            FigureView(value: idleText, label: "idle cards", colour: Theme.pending, size: .small, dimmed: isStale)
        }
    }

    private var sparklineColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            GpuSparkline(values: data.sparklineValues, colour: Theme.running, dimmed: isStale)
            sparklineCaption
        }
    }

    private var sparklineCaption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(data.sparklineLabel)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 2)
            Text(Format.percent(data.currentSparklineValue))
                .font(Theme.footerValueFont)
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// Large: the node grid with compact cells and the legend as footer.
struct GpuLargeView: View {
    static let maxRows = 8

    let data: GpuData
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.footerGap) {
            GeometryReader { (proxy: GeometryProxy) in
                GpuGridArea(data: data, areaSize: proxy.size, metrics: GpuGridMetrics.large, maxRows: GpuLargeView.maxRows, isStale: isStale)
            }
            Hairline()
            GpuLegend(metricsAvailable: data.metricsAvailable, perLine: 5, isStale: isStale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The grid fitted into a given area, or a note when there are no GPU nodes.
struct GpuGridArea: View {
    let data: GpuData
    let areaSize: CGSize
    let metrics: GpuGridMetrics
    let maxRows: Int
    var isStale: Bool = false

    var body: some View {
        if data.nodes.isEmpty {
            Text("No GPU nodes")
                .font(Theme.footerFont)
                .foregroundStyle(Theme.secondaryText)
        } else {
            GpuNodeGrid(plan: plan, width: areaSize.width, metrics: metrics, isStale: isStale)
        }
    }

    private var plan: GpuGridPlan {
        GpuGridPlan.fitting(groups: data.typeGroups, maxRows: maxRows, height: areaSize.height, metrics: metrics)
    }
}

/// Extra large: the grid with wide cells, and a side column with the top
/// users, the legend and the pending line.
struct GpuExtraLargeView: View {
    static let maxRows = 8
    static let maxUsers = 5
    static let sideWidth: CGFloat = 136

    let data: GpuData
    var isStale: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GeometryReader { (proxy: GeometryProxy) in
                GpuGridArea(data: data, areaSize: proxy.size, metrics: GpuGridMetrics.extraLarge, maxRows: GpuExtraLargeView.maxRows, isStale: isStale)
            }
            divider
            GpuSideColumn(data: data, isStale: isStale)
                .frame(width: GpuExtraLargeView.sideWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: Theme.Spacing.hairlineHeight)
            .frame(maxHeight: .infinity)
    }
}

/// The right-hand column of the extra large layout.
struct GpuSideColumn: View {
    let data: GpuData
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Top users · cards")
            users
            Spacer(minLength: 4)
            GpuLegend(metricsAvailable: data.metricsAvailable, perLine: 2, isStale: isStale)
            Hairline()
            pendingText
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var shownUsers: [GpuUserCards] {
        Array(data.topUsers.prefix(GpuExtraLargeView.maxUsers))
    }

    @ViewBuilder
    private var users: some View {
        if shownUsers.isEmpty {
            Text("No cards allocated")
                .font(Theme.footerFont)
                .foregroundStyle(Theme.secondaryText)
        } else {
            ForEach(shownUsers) { (user: GpuUserCards) in
                userRow(user)
            }
        }
    }

    private func userRow(_ user: GpuUserCards) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(user.user)
                .font(Theme.figureFont(size: 11, weight: .regular))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(user.cards)")
                .font(Theme.footerValueFont)
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale))
                .lineLimit(1)
        }
    }

    private var pendingColour: Color {
        data.pendingJobs > 0 ? Theme.pending : Theme.secondaryText
    }

    private var pendingText: some View {
        Text(data.pendingLine)
            .font(Theme.footerFont)
            .foregroundStyle(Theme.figure(pendingColour, dimmed: isStale))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
