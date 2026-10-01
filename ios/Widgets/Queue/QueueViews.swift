import SlurmKit
import SwiftUI

// The three queue layouts. Each draws the body below the header and takes
// the data and the stale flag as plain values.

/// Small: running and pending side by side, footer with the user's jobs.
struct QueueSmallView: View {
    let data: QueueData
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            figures
            Spacer(minLength: 0)
            FooterRow(left: "mine", right: data.mineLine, dimmed: isStale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var figures: some View {
        HStack(alignment: .top, spacing: 10) {
            FigureView(value: "\(data.running)", label: "running", colour: Theme.running, size: .large, dimmed: isStale)
                .frame(maxWidth: .infinity, alignment: .leading)
            FigureView(value: "\(data.pending)", label: "pending", colour: Theme.pending, size: .large, dimmed: isStale)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Medium: figures stacked on the left, pending reasons as bars on the right.
struct QueueMediumView: View {
    static let maxReasons = 4

    let data: QueueData
    var isStale: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.column) {
            figures
                .frame(width: 84, alignment: .leading)
            reasons
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var figures: some View {
        VStack(alignment: .leading, spacing: 8) {
            FigureView(value: "\(data.running)", label: "running", colour: Theme.running, size: .medium, dimmed: isStale)
            FigureView(value: "\(data.pending)", label: "pending", colour: Theme.pending, size: .medium, dimmed: isStale)
        }
    }

    private var shownReasons: [ReasonCount] {
        Array(data.pendingByReason.prefix(QueueMediumView.maxReasons))
    }

    private var largestCount: Int {
        shownReasons.map { $0.count }.max() ?? 0
    }

    private func fraction(_ reason: ReasonCount) -> Double {
        let largest: Int = largestCount
        if largest <= 0 {
            return 0
        }
        return Double(reason.count) / Double(largest)
    }

    @ViewBuilder
    private var reasons: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Pending, by reason")
            if shownReasons.isEmpty {
                Text("Nothing pending")
                    .font(Theme.footerFont)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                reasonBars
            }
        }
    }

    private var reasonBars: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(shownReasons) { (reason: ReasonCount) in
                LabelledBar(
                    label: reason.reason,
                    fraction: fraction(reason),
                    value: "\(reason.count)",
                    colour: Theme.pending,
                    dimmed: isStale
                )
            }
        }
    }
}

/// Large: the user's jobs, up to seven rows.
struct QueueLargeView: View {
    static let maxRows = 7

    let data: QueueData
    var isStale: Bool = false
    var timeZone: TimeZone = TimeZone.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                emptyMessage
            } else {
                rowList
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rows: [JobSummary] {
        Array(data.myJobs.prefix(QueueLargeView.maxRows))
    }

    private var rowList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.jobId) { item in
                if item.offset > 0 {
                    Hairline()
                }
                QueueJobRow(job: item.element, isStale: isStale, timeZone: timeZone)
                    .padding(.vertical, 5)
            }
        }
    }

    private var emptyMessage: some View {
        Text(data.mine == nil ? "No user is set, so no jobs are listed." : "None of your jobs are running or pending.")
            .font(Theme.footerFont)
            .foregroundStyle(Theme.secondaryText)
            .padding(.top, 4)
    }

    @ViewBuilder
    private var footer: some View {
        let more: Int = data.moreJobsCount(shown: rows.count)
        if more > 0 {
            FooterRow(left: "and \(more) more", right: "", dimmed: isStale)
        }
    }
}

/// One job: state chip, name with partition and resources, and the time column.
struct QueueJobRow: View {
    let job: JobSummary
    var isStale: Bool = false
    var timeZone: TimeZone = TimeZone.current

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            StateChip(text: chipText, colour: chipColour, dimmed: isStale)
            nameColumn
            Spacer(minLength: 6)
            timeColumn
        }
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(job.name)
                .font(Theme.figureFont(size: 12, weight: .medium))
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(job.partition + " · " + job.resources)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(timeValue)
                .font(Theme.figureFont(size: 12, weight: .medium))
                .foregroundStyle(Theme.figure(Theme.primaryText, dimmed: isStale))
                .lineLimit(1)
                .fixedSize()
            Text(timeLabel)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var chipText: String {
        switch job.state {
        case .running: return "R"
        case .pending: return "PD"
        case .unknown: return "?"
        }
    }

    private var chipColour: Color {
        switch job.state {
        case .running: return Theme.running
        case .pending: return Theme.pending
        case .unknown: return Theme.secondaryText
        }
    }

    private var timeValue: String {
        switch job.state {
        case .running:
            return Format.elapsedOverLimit(elapsedSeconds: job.elapsedSeconds, limitSeconds: job.timeLimitSeconds)
        case .pending:
            if let start = job.estimatedStart {
                return Format.estimatedStart(start, timeZone: timeZone)
            }
            return job.reason ?? Format.dash
        case .unknown:
            return Format.dash
        }
    }

    private var timeLabel: String {
        switch job.state {
        case .running:
            return "elapsed"
        case .pending:
            return job.estimatedStart == nil ? "reason" : "est. start"
        case .unknown:
            return ""
        }
    }
}
