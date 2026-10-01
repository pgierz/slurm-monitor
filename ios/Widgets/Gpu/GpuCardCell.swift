import SlurmKit
import SwiftUI

/// Colours of one card cell, by card state.
struct GpuCardStyle {
    let fill: Color
    let outline: Color
    /// The state text or the utilisation.
    let text: Color
    /// Memory, temperature and power in the wide cell.
    let detail: Color
    /// The memory bar along the bottom.
    let bar: Color

    static func make(for state: CardState, dimmed: Bool) -> GpuCardStyle {
        if dimmed {
            let fill: Color = state.isAllocated ? Theme.track : Color.clear
            return GpuCardStyle(fill: fill, outline: Theme.staleFigure, text: Theme.staleFigure, detail: Theme.staleFigure, bar: Theme.staleFigure)
        }
        switch state {
        case .busy, .allocated:
            return GpuCardStyle(fill: Theme.gpuBusyFill, outline: Theme.running, text: Theme.primaryText, detail: Theme.secondaryText, bar: Theme.running)
        case .idleAllocated:
            return GpuCardStyle(fill: Theme.gpuIdleAllocatedFill, outline: Theme.pending, text: Theme.pending, detail: Theme.pending, bar: Theme.pending)
        case .free, .unknown:
            return GpuCardStyle(fill: Color.clear, outline: Theme.idleOutline, text: Theme.secondaryText, detail: Theme.secondaryText, bar: Theme.idleOutline)
        case .drained:
            return GpuCardStyle(fill: Color.clear, outline: Theme.drained, text: Theme.drained, detail: Theme.drained, bar: Theme.drained)
        case .down:
            return GpuCardStyle(fill: Color.clear, outline: Theme.down, text: Theme.down, detail: Theme.down, bar: Theme.down)
        }
    }
}

/// Measures of the card cells. Kept apart from the views, so that the grid
/// arithmetic does not depend on a view type.
enum GpuCardMetrics {
    static let height: CGFloat = 30
    /// Cell width of the large layout.
    static let compactWidth: CGFloat = 58
    /// Cell width of the extra large layout.
    static let wideWidth: CGFloat = 112
    /// Below this width a wide cell falls back to the short text.
    static let detailMinimumWidth: CGFloat = 92
    static let memoryBarHeight: CGFloat = 3
}

/// One GPU card: a rounded cell with the utilisation or the state text and
/// a memory bar along the bottom. The width is given by the grid, so that
/// nodes with many cards still fit.
struct GpuCardCell: View {
    let card: GpuCard
    let width: CGFloat
    /// True in the extra large layout: memory, temperature and power beside the utilisation.
    var showsDetail: Bool = false
    var isStale: Bool = false

    var body: some View {
        label
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 3)
            .frame(width: width, height: GpuCardMetrics.height)
            .background(style.fill)
            .overlay(alignment: .bottomLeading) {
                memoryBar
            }
            .clipShape(cellShape)
            .overlay(cellShape.strokeBorder(style.outline, lineWidth: 1))
    }

    private var style: GpuCardStyle {
        GpuCardStyle.make(for: card.state, dimmed: isStale)
    }

    private var cellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    /// Metrics are shown only for allocated cards that report them.
    private var hasMetrics: Bool {
        card.state.isAllocated && card.utilisation != nil
    }

    private var showsDetailLine: Bool {
        showsDetail && hasMetrics && width >= GpuCardMetrics.detailMinimumWidth
    }

    @ViewBuilder
    private var label: some View {
        if showsDetailLine {
            detailLine
        } else {
            stateText
        }
    }

    private var stateText: some View {
        Text(Format.cardText(card))
            .font(Theme.figureFont(size: 10, weight: .semibold))
            .foregroundStyle(style.text)
    }

    private var detailLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            stateText
            detailText(Format.memoryGigabytes(mib: card.memoryUsedMib))
            detailText(Format.temperature(celsius: card.temperatureC))
            detailText(Format.power(watts: card.powerW))
        }
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(Theme.figureFont(size: 9, weight: .regular))
            .foregroundStyle(style.detail)
    }

    @ViewBuilder
    private var memoryBar: some View {
        if let fraction = card.memoryFraction, fraction > 0 {
            Rectangle()
                .fill(style.bar)
                .frame(width: max(2, width * CGFloat(fraction)), height: GpuCardMetrics.memoryBarHeight)
        }
    }
}
