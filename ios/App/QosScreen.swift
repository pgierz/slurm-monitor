import SlurmKit
import SwiftUI

/// The QOS section.
struct QosScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var content: WidgetContent<QosData>? = nil

    var body: some View {
        FamilyScaffold(
            title: "QOS",
            content: content,
            reload: { await load() },
            openSettings: { model.selection = .settings }
        ) { data, tone in
            QosDetail(data: data, tone: tone)
        }
        .task(id: ReloadKey(revision: model.revision, partition: nil)) {
            await load()
        }
    }

    private func load() async {
        let result = await model.makeLoader().qos()
        if Task.isCancelled { return }
        content = result
    }
}

/// The QOS content for one snapshot.
struct QosDetail: View {
    let data: QosData
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            usagePanel
            fairsharePanel
        }
    }

    private var usagePanel: some View {
        Panel("QOS · CPUs in use") {
            if data.qos.isEmpty {
                NoteText("No QOS has jobs or a limit at the moment.")
            } else {
                ForEach(data.qos) { entry in
                    QosRow(entry: entry, tone: tone)
                    if entry.id != data.qos.last?.id {
                        Hairline()
                    }
                }
            }
        }
    }

    private var fairsharePanel: some View {
        Panel("Fairshare · my account") {
            HStack(alignment: .firstTextBaseline) {
                Text(accountText)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                Text(Format.fairshare(data.fairshare))
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(tone.primary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(fairshareAccessibilityLabel)
            if let fairshare = data.fairshare {
                MeterBar(fraction: fairshare, colour: tone.blue)
            } else if data.user == nil {
                NoteText("Enter your Slurm username in Settings to see your fairshare.")
            } else {
                NoteText("The accounting database reports no fairshare for this user.")
            }
        }
    }

    private var accountText: String {
        let user = data.user ?? Format.dash
        if let account = data.account {
            return "\(user) · account \(account)"
        }
        return user
    }

    private var fairshareAccessibilityLabel: String {
        guard data.fairshare != nil else { return "Fairshare: not known" }
        return "Fairshare of \(accountText): \(Format.fairshare(data.fairshare))"
    }
}

private struct QosRow: View {
    let entry: QosEntry
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Palette.primary)
                Spacer(minLength: 8)
                Text(entry.usageText)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(entry.isNearLimit ? tone.amber : tone.primary)
            }
            if let fraction = entry.usedFraction {
                MeterBar(fraction: fraction, colour: entry.isNearLimit ? tone.amber : tone.blue)
            }
            Text(detailText)
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var detailText: String {
        var parts: [String] = []
        if entry.usedFraction == nil {
            parts.append("no CPU limit")
        }
        parts.append("\(entry.runningJobs) running")
        parts.append("\(entry.pendingJobs) pending")
        if let wall = entry.maxWallSeconds {
            parts.append("max " + Format.hoursMinutes(seconds: wall))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var text = "QOS \(entry.name): \(entry.cpusInUse) CPUs in use"
        if let limit = entry.cpuLimit {
            text += " of \(limit)"
        }
        if entry.isNearLimit {
            text += ", near the limit"
        }
        text += ", \(entry.runningJobs) jobs running, \(entry.pendingJobs) pending"
        return text
    }
}

#Preview("QOS") {
    ScrollView {
        QosDetail(data: SampleData.qos.data, tone: Tone(stale: false))
            .padding()
    }
    .background(Palette.background)
    .preferredColorScheme(.dark)
}
