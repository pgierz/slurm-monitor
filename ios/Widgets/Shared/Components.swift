import SwiftUI

// Reusable pieces of the widget layouts. Each takes plain values. `dimmed`
// switches figures and bars to the stale grey; pass the `isStale` flag the
// container hands to the live view.

/// Header row: title in small capitals style on the left, the snapshot time
/// on the right, optionally the refresh button.
struct WidgetHeader: View {
    let title: String
    /// `HH:mm`, `as of HH:mm`, or `—`.
    let time: String
    /// True shows the time in amber (stale: "as of 13:05").
    var timeIsStale: Bool = false
    var showsRefresh: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.titleFont)
                .tracking(Theme.titleTracking)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Text(time)
                .font(Theme.timeFont)
                .foregroundStyle(timeIsStale ? Theme.pending : Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
            if showsRefresh {
                RefreshButton()
            }
        }
    }
}

/// Size of a `FigureView`.
enum FigureSize {
    /// 32 pt, the main figures of small widgets.
    case large
    /// 24 pt, stacked figures in medium widgets.
    case medium
    /// 15 pt, rows of small figures.
    case small

    var pointSize: CGFloat {
        switch self {
        case .large: return 32
        case .medium: return 24
        case .small: return 15
        }
    }
}

/// A figure in the monospaced design with a small label below it.
struct FigureView: View {
    let value: String
    let label: String
    var colour: Color = Theme.primaryText
    var size: FigureSize = .large
    var dimmed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.figureLabel) {
            Text(value)
                .font(Theme.figureFont(size: size.pointSize))
                .foregroundStyle(Theme.figure(colour, dimmed: dimmed))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }
}

/// A small label in the secondary colour, for example "Pending, by reason".
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.labelFont)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
    }
}

/// A horizontal bar filled to `fraction` (0…1) on a track.
struct ProportionalBar: View {
    let fraction: Double
    var colour: Color = Theme.running
    var height: CGFloat = Theme.Spacing.barHeight
    var dimmed: Bool = false

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.figure(colour, dimmed: dimmed))
                    .frame(width: fillWidth(proxy.size.width))
            }
        }
        .frame(height: height)
    }

    private func fillWidth(_ total: CGFloat) -> CGFloat {
        let clamped: Double = min(1.0, max(0.0, fraction))
        if clamped <= 0 {
            return 0
        }
        return max(height, total * CGFloat(clamped))
    }
}

/// One row: label, bar, value. Used for pending reasons, QOS and GPU types.
struct LabelledBar: View {
    let label: String
    let fraction: Double
    let value: String
    var colour: Color = Theme.running
    /// Fixed width of the label column, so that bars in a group line up.
    var labelWidth: CGFloat = 68
    /// Fixed width of the value column.
    var valueWidth: CGFloat = 28
    var dimmed: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: labelWidth, alignment: .leading)
            ProportionalBar(fraction: fraction, colour: colour, dimmed: dimmed)
            Text(value)
                .font(Theme.footerValueFont)
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: dimmed))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }
}

/// One segment of a `StackedBar`.
struct BarSegment {
    /// Any non-negative weight; the bar normalises by the sum.
    let weight: Double
    let colour: Color
}

/// A bar of adjoining segments, for example the four node states.
/// When `dimmed`, the segments are drawn in the stale grey at falling opacity.
struct StackedBar: View {
    let segments: [BarSegment]
    var height: CGFloat = Theme.Spacing.barHeight
    var dimmed: Bool = false

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.track)
                segmentRow(width: proxy.size.width)
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }

    private func segmentRow(width: CGFloat) -> some View {
        let widths: [CGFloat] = segmentWidths(total: width)
        return HStack(spacing: 0) {
            ForEach(0..<widths.count, id: \.self) { (index: Int) in
                Rectangle()
                    .fill(segmentColour(index))
                    .frame(width: widths[index])
            }
        }
    }

    private func segmentWidths(total: CGFloat) -> [CGFloat] {
        let weights: [Double] = segments.map { max(0.0, $0.weight) }
        let sum: Double = weights.reduce(0.0, +)
        if sum <= 0 {
            return segments.map { _ in CGFloat(0) }
        }
        return weights.map { total * CGFloat($0 / sum) }
    }

    private func segmentColour(_ index: Int) -> Color {
        if !dimmed {
            return segments[index].colour
        }
        let opacities: [Double] = [1.0, 0.6, 0.4, 0.25]
        let opacity: Double = opacities[min(index, opacities.count - 1)]
        return Theme.staleFigure.opacity(opacity)
    }
}

/// A hairline across the available width.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: Theme.Spacing.hairlineHeight)
            .frame(maxWidth: .infinity)
    }
}

/// Footer: a hairline, then a label on the left and a value on the right.
struct FooterRow: View {
    let left: String
    let right: String
    /// Colour of the value; amber for values that need attention.
    var rightColour: Color = Theme.primaryText
    var dimmed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.footerGap) {
            Hairline()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(left)
                    .font(Theme.footerFont)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(right)
                    .font(Theme.footerValueFont)
                    .foregroundStyle(Theme.figure(rightColour, dimmed: dimmed))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

/// Legend entry: a small colour swatch, a label and optionally a count.
struct LegendItem: View {
    let colour: Color
    let label: String
    var value: String? = nil
    /// Draws the swatch with this outline (for example white for "down" in the node grid).
    var outline: Color? = nil
    var dimmed: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            swatch
            Text(label)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            if let value = value {
                Text(value)
                    .font(Theme.figureFont(size: 10, weight: .medium))
                    .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: dimmed))
                    .lineLimit(1)
            }
        }
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(colour)
            .frame(width: 7, height: 7)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(outline ?? Color.clear, lineWidth: 1)
            )
    }
}

/// A state chip: short monospaced text in an outline, `R` blue or `PD` amber.
struct StateChip: View {
    let text: String
    let colour: Color
    var width: CGFloat = 26
    var dimmed: Bool = false

    var body: some View {
        Text(text)
            .font(Theme.figureFont(size: 10, weight: .semibold))
            .foregroundStyle(Theme.figure(colour, dimmed: dimmed))
            .lineLimit(1)
            .frame(width: width, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Theme.figure(colour, dimmed: dimmed), lineWidth: 1)
            )
    }
}
