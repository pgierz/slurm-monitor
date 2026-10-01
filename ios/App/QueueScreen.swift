import SlurmKit
import SwiftUI

/// The Queue section: loads the snapshot and offers the partition filter.
struct QueueScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var content: WidgetContent<QueueData>? = nil
    @State private var partition: String?

    init(initialPartition: String?) {
        _partition = State(initialValue: initialPartition)
    }

    var body: some View {
        FamilyScaffold(
            title: "Queue",
            content: content,
            reload: { await load() },
            openSettings: { model.selection = .settings }
        ) { data, tone in
            QueueDetail(data: data, tone: tone)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PartitionMenu(selection: $partition, names: model.partitionChoices(including: partition))
            }
        }
        .task(id: ReloadKey(revision: model.revision, partition: partition)) {
            await load()
        }
    }

    private func load() async {
        let result = await model.makeLoader().queue(partition: partition)
        if Task.isCancelled { return }
        content = result
        if result.value != nil {
            await model.learnPartitionsIfNeeded()
        }
    }
}

/// The Queue content for one snapshot.
struct QueueDetail: View {
    let data: QueueData
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            figuresPanel
            reasonsPanel
            historyPanel
            jobsPanel
        }
    }

    private var scopeTitle: String {
        "Queue · " + (data.partition ?? "all partitions")
    }

    private var figuresPanel: some View {
        Panel(scopeTitle) {
            HStack(alignment: .top, spacing: 16) {
                FigureView(value: "\(data.running)", label: "running", colour: tone.blue)
                FigureView(value: "\(data.pending)", label: "pending", colour: tone.amber)
            }
            Hairline()
            HStack {
                Text("mine")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                Text(data.mineLine)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(tone.primary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mineAccessibilityLabel)
        }
    }

    private var mineAccessibilityLabel: String {
        guard let mine = data.mine else { return "My jobs: not known" }
        return "My jobs: \(mine.running) running, \(mine.pending) pending"
    }

    private var reasonsPanel: some View {
        Panel("Pending, by reason") {
            if data.pendingByReason.isEmpty {
                NoteText("No job is pending.")
            } else {
                ForEach(data.pendingByReason) { entry in
                    ReasonRow(entry: entry, largest: largestReasonCount, tone: tone)
                }
            }
        }
    }

    private var largestReasonCount: Int {
        data.pendingByReason.map { $0.count }.max() ?? 0
    }

    private var historyPanel: some View {
        Panel("Running and pending, last hours") {
            if data.history.count < 2 {
                NoteText("No history yet.")
            } else {
                HistoryChart(
                    samples: historySamples,
                    seriesNames: ["Running", "Pending"],
                    seriesColours: [tone.blue, tone.amber],
                    summary: historySummary
                )
            }
        }
    }

    private var historySamples: [HistorySample] {
        var samples: [HistorySample] = []
        for (index, point) in data.history.enumerated() {
            samples.append(HistorySample(id: index * 2, time: point.t, value: Double(point.running), series: "Running"))
            samples.append(HistorySample(id: index * 2 + 1, time: point.t, value: Double(point.pending), series: "Pending"))
        }
        return samples
    }

    private var historySummary: String {
        guard let first = data.history.first, let last = data.history.last else {
            return "Queue history: no data"
        }
        let start = Format.clockTime(first.t, timeZone: .current)
        let end = Format.clockTime(last.t, timeZone: .current)
        return "Queue history from \(start) to \(end). Running went from \(first.running) to \(last.running), pending from \(first.pending) to \(last.pending)."
    }

    private var jobsPanel: some View {
        Panel("My jobs", trailing: data.mine == nil ? nil : data.mineLine) {
            if data.mine == nil {
                NoteText("Enter your Slurm username in Settings to see your jobs.")
            } else if data.myJobs.isEmpty {
                NoteText("You have no running or pending job.")
            } else {
                ForEach(data.myJobs) { job in
                    JobRow(job: job, tone: tone)
                    if job.id != data.myJobs.last?.id {
                        Hairline()
                    }
                }
                if moreJobs > 0 {
                    NoteText("and \(moreJobs) more")
                }
            }
        }
    }

    private var moreJobs: Int {
        data.moreJobsCount(shown: data.myJobs.count)
    }
}

private struct ReasonRow: View {
    let entry: ReasonCount
    let largest: Int
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.reason)
                    .font(.subheadline)
                    .foregroundStyle(Palette.primary)
                Spacer(minLength: 8)
                Text("\(entry.count)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(tone.primary)
            }
            MeterBar(fraction: largest > 0 ? Double(entry.count) / Double(largest) : 0, colour: tone.amber)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.reason): \(entry.count) pending")
    }
}

private struct JobRow: View {
    let job: JobSummary
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StateChip(state: job.state, tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Palette.primary)
                    .lineLimit(2)
                Text("\(job.partition) · \(job.resources) · \(String(job.jobId))")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(rightValue)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(tone.primary)
                Text(rightLabel)
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var rightValue: String {
        if job.state == .running {
            return Format.elapsedOverLimit(elapsedSeconds: job.elapsedSeconds, limitSeconds: job.timeLimitSeconds)
        }
        if let start = job.estimatedStart {
            return Format.estimatedStart(start, timeZone: .current)
        }
        return job.reason ?? Format.dash
    }

    private var rightLabel: String {
        if job.state == .running {
            return "elapsed"
        }
        if job.estimatedStart != nil {
            return "est. start"
        }
        return "reason"
    }

    private var accessibilityText: String {
        let stateWord: String
        switch job.state {
        case .running: stateWord = "running"
        case .pending: stateWord = "pending"
        case .unknown: stateWord = "state not known"
        }
        return "\(job.name), \(stateWord), \(job.partition), \(job.resources), \(rightLabel) \(rightValue)"
    }
}

private struct StateChip: View {
    let state: JobState
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(colour)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(colour, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    private var text: String {
        switch state {
        case .running: return "R"
        case .pending: return "PD"
        case .unknown: return "?"
        }
    }

    private var colour: Color {
        switch state {
        case .running: return tone.blue
        case .pending: return tone.amber
        case .unknown: return Palette.secondary
        }
    }
}

#Preview("Queue") {
    ScrollView {
        QueueDetail(data: SampleData.queue.data, tone: Tone(stale: false))
            .padding()
    }
    .background(Palette.background)
    .preferredColorScheme(.dark)
}

#Preview("Queue, stale") {
    ScrollView {
        QueueDetail(data: SampleData.queue.data, tone: Tone(stale: true))
            .padding()
    }
    .background(Palette.background)
    .preferredColorScheme(.dark)
}
