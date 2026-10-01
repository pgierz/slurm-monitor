import SwiftUI

/// The colours of the mockups. The app is always dark, like the widgets.
enum Palette {
    static let background = rgb(0x0E1318)
    static let panel = rgb(0x151C23)
    static let primary = rgb(0xEEF2F6)
    static let secondary = rgb(0x9AA7B4)
    static let blue = rgb(0x3F8FE0)
    static let amber = rgb(0xFFC073)
    static let track = rgb(0x26323E)
    static let trackOutline = rgb(0x5B6B7B)
    static let idleSegment = rgb(0x45586B)
    static let drained = rgb(0x8A96A3)
    static let down = rgb(0xFF8A80)
    static let busyCardFill = rgb(0x14324F)
    static let idleCardFill = rgb(0x3A2A12)
    static let stale = rgb(0x6F7C89)
    static let hairline = rgb(0x26323E)

    static func rgb(_ value: UInt32) -> Color {
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

/// The colours of figures and bars; all turn grey for a stale snapshot.
struct Tone: Equatable {
    var stale: Bool

    var primary: Color { stale ? Palette.stale : Palette.primary }
    var blue: Color { stale ? Palette.stale : Palette.blue }
    var amber: Color { stale ? Palette.stale : Palette.amber }
    var idle: Color { stale ? Palette.track : Palette.idleSegment }
    var drained: Color { stale ? Palette.stale : Palette.drained }
    var down: Color { stale ? Palette.stale : Palette.down }
}

/// A titled block on the panel colour.
struct Panel<Content: View>: View {
    private let title: String
    private let trailing: String?
    private let content: Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let trailing = trailing {
                    Text(trailing)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.panel)
        )
    }
}

/// A large monospaced figure with a small label below.
struct FigureView: View {
    let value: String
    let label: String
    let colour: Color
    var large: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(figureFont)
                .foregroundStyle(colour)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    private var figureFont: Font {
        if large {
            return Font.system(.largeTitle, design: .monospaced).weight(.semibold)
        }
        return Font.system(.title2, design: .monospaced).weight(.semibold)
    }
}

/// A horizontal bar on a track, filled to a fraction.
struct MeterBar: View {
    let fraction: Double
    let colour: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(colour)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var clamped: CGFloat {
        CGFloat(min(1, max(0, fraction)))
    }
}

/// One segment of a stacked bar.
struct BarSegment: Identifiable {
    let id: Int
    let fraction: Double
    let colour: Color
}

/// A bar of adjoining segments, for the four node states.
struct StackedBar: View {
    let segments: [BarSegment]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.colour)
                        .frame(width: proxy.size.width * CGFloat(max(0, segment.fraction)))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .background(Palette.track)
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// A coloured dot with a label, for legends.
struct LegendItem: View {
    let colour: Color
    let text: String
    var outlined: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(outlined ? Color.clear : colour)
                .overlay(Circle().stroke(colour, lineWidth: 1.5))
                .frame(width: 9, height: 9)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A thin separating line.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A one-line note in the secondary colour.
struct NoteText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
