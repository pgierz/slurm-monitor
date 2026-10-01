import SlurmKit
import SwiftUI
import WidgetKit

extension Color {
    /// A colour from a 24-bit RGB value, for example `Color(hex: 0x0E1318)`.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}

/// Palette, type styles and spacing from docs/mockups.md. The widgets are
/// always dark, so every colour is explicit.
enum Theme {
    // MARK: Palette

    static let background = Color(hex: 0x0E1318)
    static let primaryText = Color(hex: 0xEEF2F6)
    static let secondaryText = Color(hex: 0x9AA7B4)
    /// Allocated / running (blue).
    static let running = Color(hex: 0x3F8FE0)
    /// Pending / needs attention (amber).
    static let pending = Color(hex: 0xFFC073)
    /// Idle node cell fill and the track of bars.
    static let track = Color(hex: 0x26323E)
    /// Outline of idle node cells.
    static let idleOutline = Color(hex: 0x5B6B7B)
    /// Idle segment in rings and stacked bars.
    static let idleSegment = Color(hex: 0x45586B)
    static let drained = Color(hex: 0x8A96A3)
    /// Down (light red).
    static let down = Color(hex: 0xFF8A80)
    static let gpuBusyFill = Color(hex: 0x14324F)
    static let gpuIdleAllocatedFill = Color(hex: 0x3A2A12)
    /// Figures and bars of a stale widget.
    static let staleFigure = Color(hex: 0x6F7C89)
    /// Hairlines between rows and above footers.
    static let hairline = Color(hex: 0x26323E)

    /// `colour`, or the stale grey when `dimmed`.
    static func figure(_ colour: Color, dimmed: Bool) -> Color {
        dimmed ? staleFigure : colour
    }

    /// Segment colour of a node state in rings, stacked bars and legends.
    static func colour(for state: NodeState) -> Color {
        switch state {
        case .allocated: return running
        case .idle: return idleSegment
        case .drained: return drained
        case .down: return down
        case .unknown: return idleSegment
        }
    }

    // MARK: Type

    /// Header title: 11 pt semibold; set in upper case with tracking by `WidgetHeader`.
    static let titleFont = Font.system(size: 11, weight: .semibold)
    static let titleTracking: CGFloat = 0.6
    /// Header time: 11 pt monospaced.
    static let timeFont = Font.system(size: 11, weight: .regular, design: .monospaced)
    /// Small labels under figures, section labels, legends.
    static let labelFont = Font.system(size: 10, weight: .regular)
    /// Footer text, default design.
    static let footerFont = Font.system(size: 11, weight: .regular)
    /// Footer values and other small figures.
    static let footerValueFont = Font.system(size: 11, weight: .medium, design: .monospaced)

    /// A figure in the monospaced design at any size.
    static func figureFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Spacing

    enum Spacing {
        /// Between the header row and the body.
        static let headerGap: CGFloat = 8
        /// Between a hairline and the footer text below it.
        static let footerGap: CGFloat = 6
        /// Between rows of bars or list rows.
        static let row: CGFloat = 6
        /// Between columns.
        static let column: CGFloat = 14
        /// Between a figure and its label.
        static let figureLabel: CGFloat = 1
        static let hairlineHeight: CGFloat = 0.5
        static let barHeight: CGFloat = 6
    }
}

/// The Home Screen sizes the layouts distinguish. Views take this as a plain
/// value; only the top-level entry view of a widget reads
/// `@Environment(\.widgetFamily)` and converts it.
enum WidgetLayoutSize: Equatable {
    case small
    case medium
    case large
    case extraLarge

    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .systemLarge: self = .large
        case .systemExtraLarge: self = .extraLarge
        default: self = .small
        }
    }
}

/// Deep links from the widgets into the app.
enum WidgetLinks {
    /// `de.awi.slurm-monitor://family/<kind>`.
    static func family(_ kind: WidgetFamilyKind) -> URL? {
        URL(string: "de.awi.slurm-monitor://family/" + kind.rawValue)
    }
}
