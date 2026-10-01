import SlurmKit
import SwiftUI
import WidgetKit

/// One arc of a `NodesRing`, as fractions of the full circle.
struct NodesRingArc: Identifiable {
    let id: Int
    let start: CGFloat
    let end: CGFloat
    let colour: Color
    /// Stroke width; thinner than the ring for the hollow state in reduced colour.
    let lineWidth: CGFloat
    /// Belongs to the accent group of the tinted Home Screen.
    let accent: Bool
}

/// A ring with four segments: allocated, idle, drained, down, clockwise from
/// the top. When `dimmed`, the segments are drawn in the stale grey at
/// falling opacity. In reduced colour the segments differ by opacity, and
/// the down segment is a thin line.
struct NodesRing: View {
    static let states: [NodeState] = [.allocated, .idle, .drained, .down]

    let counts: NodeStateCounts
    var lineWidth: CGFloat = 9
    var dimmed: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.trackColour(reduced: reduced), lineWidth: lineWidth)
            ForEach(arcs) { (arc: NodesRingArc) in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.colour, style: StrokeStyle(lineWidth: arc.lineWidth, lineCap: .butt))
                    .rotationEffect(Angle(degrees: -90))
                    .widgetAccentable(arc.accent)
            }
        }
        .padding(lineWidth / 2)
    }

    private var arcs: [NodesRingArc] {
        let fractions: [Double] = counts.fractions
        var result: [NodesRingArc] = []
        var start: Double = 0
        for index in 0..<fractions.count {
            let end: Double = min(1.0, start + fractions[index])
            if end > start {
                result.append(
                    NodesRingArc(
                        id: index,
                        start: CGFloat(start),
                        end: CGFloat(end),
                        colour: colour(index),
                        lineWidth: arcWidth(index),
                        accent: index == 0
                    )
                )
            }
            start = end
        }
        return result
    }

    private func state(_ index: Int) -> NodeState {
        NodesRing.states[min(index, NodesRing.states.count - 1)]
    }

    private func arcWidth(_ index: Int) -> CGFloat {
        if reduced && Theme.isHollowWhenReduced(state(index)) {
            return max(2, lineWidth / 3)
        }
        return lineWidth
    }

    private func colour(_ index: Int) -> Color {
        if reduced {
            return Theme.reducedColour(for: state(index), dimmed: dimmed)
        }
        if dimmed {
            let opacities: [Double] = [1.0, 0.6, 0.4, 0.25]
            return Theme.staleFigure.opacity(opacities[min(index, opacities.count - 1)])
        }
        return Theme.colour(for: state(index))
    }
}
