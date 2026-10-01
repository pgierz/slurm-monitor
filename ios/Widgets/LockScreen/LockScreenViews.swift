import SlurmKit
import SwiftUI
import WidgetKit

// The Lock Screen accessories. They render in the system's vibrant mode, so
// nothing here sets a colour from the palette or a background colour.

/// Wrapper of the accessory views in place of `FamilyWidgetView`: a clear
/// widget background and the deep link, and nothing else.
struct LockAccessoryContainer<Content: View>: View {
    let kind: WidgetFamilyKind
    let content: Content

    init(kind: WidgetFamilyKind, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                Color.clear
            }
            .widgetURL(WidgetLinks.family(kind))
    }
}

/// The texts of the accessories.
enum LockScreenLogic {
    /// `12 R · 3 PD` for the user's jobs; the totals when no user is known.
    static func queueLine(_ data: QueueData) -> String {
        if let mine = data.mine {
            return Format.queueLine(running: mine.running, pending: mine.pending)
        }
        return Format.queueLine(running: data.running, pending: data.pending)
    }

    /// The one line of the inline accessory.
    static func inlineText(_ queue: WidgetContent<QueueData>) -> String {
        switch queue {
        case .live(let data, _):
            return queueLine(data)
        case .stale(let data, _):
            return queueLine(data)
        case .vpnNeeded:
            return "VPN needed"
        case .signInNeeded:
            return "Sign in needed"
        case .notConfigured:
            return "Not configured"
        }
    }

    /// Allocated nodes over all nodes, 0…1; `nil` when the state carries no data.
    static func allocatedFraction(_ nodes: WidgetContent<NodesData>) -> Double? {
        guard let data = nodes.value else { return nil }
        return min(1.0, max(0.0, data.allocatedFraction))
    }
}

/// Circular: gauge of the allocated node fraction, the percentage in the centre.
struct LockCircularView: View {
    let nodes: WidgetContent<NodesData>
    /// Draws the system's accessory backdrop behind the gauge. Off by
    /// default, because it has no meaning outside a widget.
    var showsBackdrop: Bool = false

    var body: some View {
        ZStack {
            if showsBackdrop {
                AccessoryWidgetBackground()
            }
            gauge
        }
    }

    private var gauge: some View {
        Gauge(value: LockScreenLogic.allocatedFraction(nodes) ?? 0.0, in: 0.0...1.0) {
            Text("Nodes")
        } currentValueLabel: {
            Text(valueText)
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var valueText: String {
        guard let fraction = LockScreenLogic.allocatedFraction(nodes) else { return Format.dash }
        return Format.percent(fraction)
    }
}

/// Rectangular: "Next job start", the time and the job name; the queue line
/// when the user has no pending job with an estimated start; the state name
/// when there is no data.
struct LockRectangularView: View {
    let queue: WidgetContent<QueueData>
    var timeZone: TimeZone = TimeZone.autoupdatingCurrent

    var body: some View {
        lines
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var lines: some View {
        switch queue {
        case .live(let data, _):
            dataLines(data)
        case .stale(let data, _):
            dataLines(data)
        case .vpnNeeded(let last, _):
            LockMessageLines(symbol: StateSymbols.vpnNeeded, title: "VPN needed", detail: lastSeenText(last))
        case .signInNeeded:
            LockMessageLines(symbol: StateSymbols.signInNeeded, title: "Sign in needed", detail: "Open the app")
        case .notConfigured:
            LockMessageLines(symbol: StateSymbols.notConfigured, title: "Not configured", detail: "Open the app")
        }
    }

    @ViewBuilder
    private func dataLines(_ data: QueueData) -> some View {
        if let job = data.nextPendingStart, let start = job.estimatedStart {
            LockNextStartLines(time: Format.estimatedStart(start, timeZone: timeZone), jobName: job.name)
        } else {
            LockQueueLines(title: data.mine == nil ? "Queue" : "My jobs", line: LockScreenLogic.queueLine(data))
        }
    }

    private func lastSeenText(_ last: QueueData?) -> String? {
        guard let last = last else { return nil }
        return "last seen " + LockScreenLogic.queueLine(last)
    }
}

/// "Next job start", `~ 15:40`, job name.
struct LockNextStartLines: View {
    let time: String
    let jobName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Next job start")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .widgetAccentable()
            Text(time)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(jobName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A title and the queue line `12 R · 3 PD`.
struct LockQueueLines: View {
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .widgetAccentable()
            Text(line)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A state without data: symbol and title, and a line of detail if any.
struct LockMessageLines: View {
    let symbol: String
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .widgetAccentable()
            detailText
        }
    }

    @ViewBuilder
    private var detailText: some View {
        if let detail = detail {
            Text(detail)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Inline: `12 R · 3 PD`, or the state name.
struct LockInlineView: View {
    let queue: WidgetContent<QueueData>

    var body: some View {
        Text(LockScreenLogic.inlineText(queue))
    }
}
