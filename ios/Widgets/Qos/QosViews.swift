import SlurmKit
import SwiftUI

/// Medium: one bar per QOS of CPUs in use against the limit, fairshare as footer.
struct QosMediumView: View {
    static let maxRows = 4

    let data: QosData
    var isStale: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if shownEntries.isEmpty {
                emptyMessage
            } else {
                rows
            }
            Spacer(minLength: 0)
            FooterRow(left: footerText, right: Format.fairshare(data.fairshare), dimmed: isStale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var shownEntries: [QosEntry] {
        Array(data.qos.prefix(QosMediumView.maxRows))
    }

    /// The footer label; it says how many QOS are left out when there are
    /// more than fit, as the medium widget has no room for a line of its own.
    static func footerLabel(total: Int) -> String {
        let more: Int = total - maxRows
        if more > 0 {
            return "and \(more) more · fairshare"
        }
        return "fairshare · my account"
    }

    private var footerText: String {
        QosMediumView.footerLabel(total: data.qos.count)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(shownEntries) { (entry: QosEntry) in
                QosRow(entry: entry, isStale: isStale)
            }
        }
        .padding(.top, 2)
    }

    private var emptyMessage: some View {
        Text("No QOS in use")
            .font(Theme.footerFont)
            .foregroundStyle(Theme.secondary(reduced: reduced))
    }
}

/// One QOS: name, bar, `14.2k / 18k`. Amber above 95 % of the limit. Without
/// a limit the bar is a thin track and only the CPUs in use are given.
struct QosRow: View {
    static let labelWidth: CGFloat = 44
    static let valueWidth: CGFloat = 84

    let entry: QosEntry
    var isStale: Bool = false
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        if let fraction = entry.usedFraction {
            LabelledBar(
                label: entry.name,
                fraction: fraction,
                value: entry.usageText,
                colour: entry.isNearLimit ? Theme.pending : Theme.running,
                labelWidth: QosRow.labelWidth,
                valueWidth: QosRow.valueWidth,
                dimmed: isStale
            )
        } else {
            unlimitedRow
        }
    }

    /// Laid out as `LabelledBar`, so that the columns line up.
    private var unlimitedRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(entry.name)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: QosRow.labelWidth, alignment: .leading)
            Capsule()
                .fill(Theme.trackColour(reduced: reduced))
                .frame(height: 2)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Spacing.barHeight)
            Text(Format.compactCount(entry.cpusInUse))
                .font(Theme.footerValueFont)
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale, reduced: reduced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: QosRow.valueWidth, alignment: .trailing)
        }
    }
}
