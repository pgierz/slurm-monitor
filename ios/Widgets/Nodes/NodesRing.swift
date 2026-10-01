import SlurmKit
import SwiftUI

/// One arc of a `NodesRing`, as fractions of the full circle.
struct NodesRingArc: Identifiable {
    let id: Int
    let start: CGFloat
    let end: CGFloat
    let colour: Color
}

/// A ring with four segments: allocated, idle, drained, down, clockwise from
/// the top. When `dimmed`, the segments are drawn in the stale grey at
/// falling opacity.
struct NodesRing: View {
    let counts: NodeStateCounts
    var lineWidth: CGFloat = 9
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: lineWidth)
            ForEach(arcs) { (arc: NodesRingArc) in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.colour, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(Angle(degrees: -90))
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
                    NodesRingArc(id: index, start: CGFloat(start), end: CGFloat(end), colour: colour(index))
                )
            }
            start = end
        }
        return result
    }

    private func colour(_ index: Int) -> Color {
        if dimmed {
            let opacities: [Double] = [1.0, 0.6, 0.4, 0.25]
            return Theme.staleFigure.opacity(opacities[min(index, opacities.count - 1)])
        }
        let states: [NodeState] = [.allocated, .idle, .drained, .down]
        return Theme.colour(for: states[min(index, states.count - 1)])
    }
}
