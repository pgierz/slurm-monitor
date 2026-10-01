import SwiftUI
import WidgetKit

/// The line of the sparkline. Values are fractions, 0…1, oldest first. An
/// empty history draws nothing; a single point draws a level line.
struct GpuSparklineShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points: [CGPoint] = GpuSparklineShape.points(values: values, in: rect)
        guard let first = points.first else {
            return path
        }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: rect.maxX, y: first.y))
            return path
        }
        for index in 1..<points.count {
            path.addLine(to: points[index])
        }
        return path
    }

    static func clamped(_ value: Double) -> Double {
        if !value.isFinite {
            return 0
        }
        return min(1.0, max(0.0, value))
    }

    static func points(values: [Double], in rect: CGRect) -> [CGPoint] {
        if values.isEmpty || rect.width <= 0 || rect.height <= 0 {
            return []
        }
        let lastIndex: Int = values.count - 1
        var result: [CGPoint] = []
        for index in 0..<values.count {
            let position: CGFloat = lastIndex > 0 ? CGFloat(index) / CGFloat(lastIndex) : 0
            let x: CGFloat = rect.minX + rect.width * position
            let y: CGFloat = rect.maxY - rect.height * CGFloat(clamped(values[index]))
            result.append(CGPoint(x: x, y: y))
        }
        return result
    }
}

/// Six hours of history as a line between 0 and 100 %, over a base line.
struct GpuSparkline: View {
    let values: [Double]
    var colour: Color = Theme.running
    var dimmed: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        ZStack(alignment: .center) {
            if values.isEmpty {
                emptyText
            } else {
                line
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Hairline()
        }
    }

    private var line: some View {
        GpuSparklineShape(values: values)
            .stroke(
                Theme.figure(colour, dimmed: dimmed, reduced: reduced),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
            .widgetAccentable()
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
    }

    private var emptyText: some View {
        Text("no history yet")
            .font(Theme.labelFont)
            .foregroundStyle(Theme.secondary(reduced: reduced))
            .lineLimit(1)
    }
}
