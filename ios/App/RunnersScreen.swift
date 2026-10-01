import SlurmKit
import SwiftUI

/// The Runners section.
struct RunnersScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var content: WidgetContent<RunnersData>? = nil

    var body: some View {
        FamilyScaffold(
            title: "Runners",
            content: content,
            reload: { await load() },
            openSettings: { model.selection = .settings }
        ) { data, tone in
            RunnersDetail(data: data, tone: tone)
        }
        .task(id: ReloadKey(revision: model.revision, partition: nil)) {
            await load()
        }
    }

    private func load() async {
        let result = await model.makeLoader().runners()
        if Task.isCancelled { return }
        content = result
    }
}

/// The Runners content for one snapshot.
struct RunnersDetail: View {
    let data: RunnersData
    let tone: Tone

    private let figureColumns = [GridItem(.adaptive(minimum: 120), spacing: 12, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ciPanel
            daskPanel
            jupyterPanel
            if !data.extra.isEmpty {
                extraPanel
            }
        }
    }

    private var ciPanel: some View {
        Panel("CI runners") {
            LazyVGrid(columns: figureColumns, alignment: .leading, spacing: 12) {
                FigureView(value: "\(data.ci.runnersAlive)", label: "alive", colour: tone.blue)
                FigureView(value: "\(data.ci.jobsWaiting)", label: "waiting", colour: tone.amber)
            }
            Hairline()
            HStack {
                Text("oldest wait")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                Text(data.ci.oldestWaitText)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(tone.primary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(data.ci.oldestWaitSeconds == nil ? "No CI job is waiting" : "Oldest wait: \(data.ci.oldestWaitText)")
        }
    }

    private var daskPanel: some View {
        Panel("Dask clusters · \(data.dask.clusters.count)") {
            if data.dask.clusters.isEmpty {
                NoteText("No Dask cluster is running.")
            } else {
                ForEach(data.dask.clusters) { cluster in
                    DaskRow(cluster: cluster, tone: tone)
                    if cluster.id != data.dask.clusters.last?.id {
                        Hairline()
                    }
                }
                NoteText("Dot: scheduler alive. Workers running of requested; walltime left.")
            }
        }
    }

    private var jupyterPanel: some View {
        Panel("JupyterHub") {
            LazyVGrid(columns: figureColumns, alignment: .leading, spacing: 12) {
                FigureView(value: "\(data.jupyterhub.sessions)", label: "sessions", colour: tone.blue)
                FigureView(value: "\(data.jupyterhub.withGpu)", label: "with a GPU", colour: tone.primary, large: false)
                FigureView(value: "\(data.jupyterhub.nearWalltime)", label: "near walltime", colour: tone.amber, large: false)
            }
        }
    }

    private var extraPanel: some View {
        Panel("Other kinds") {
            ForEach(data.extra) { kind in
                HStack {
                    Text(kind.label)
                        .font(.subheadline)
                        .foregroundStyle(Palette.primary)
                    Spacer(minLength: 8)
                    Text(Format.queueLine(running: kind.running, pending: kind.pending))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(tone.primary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(kind.label): \(kind.running) running, \(kind.pending) pending")
            }
        }
    }
}

private struct DaskRow: View {
    let cluster: DaskCluster
    let tone: Tone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(cluster.schedulerAlive ? tone.blue : tone.down)
                .frame(width: 9, height: 9)
            Text(cluster.label)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(Palette.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(cluster.workersText)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(tone.primary)
            Text(cluster.walltimeLeftText)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(cluster.isNearWalltime ? tone.amber : tone.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "Dask cluster \(cluster.id) of \(cluster.owner), scheduler "
        text += cluster.schedulerAlive ? "alive" : "not alive"
        text += ", \(cluster.workersRunning) of \(cluster.workersRequested) workers running"
        if cluster.walltimeLeftSeconds != nil {
            text += ", walltime left \(cluster.walltimeLeftText)"
        }
        return text
    }
}

#Preview("Runners") {
    ScrollView {
        RunnersDetail(data: SampleData.runners.data, tone: Tone(stale: false))
            .padding()
    }
    .background(Palette.background)
    .preferredColorScheme(.dark)
}
