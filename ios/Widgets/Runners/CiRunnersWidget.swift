import SlurmKit
import SwiftUI
import WidgetKit

/// Small: runners alive and jobs waiting, footer with the oldest wait.
struct CiRunnersSmallView: View {
    let data: RunnersData
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            figures
            Spacer(minLength: 0)
            FooterRow(left: "oldest wait", right: data.ci.oldestWaitText, dimmed: isStale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var figures: some View {
        HStack(alignment: .top, spacing: 10) {
            FigureView(value: "\(data.ci.runnersAlive)", label: "alive", colour: Theme.running, size: .large, dimmed: isStale, accent: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            FigureView(value: "\(data.ci.jobsWaiting)", label: "waiting", colour: Theme.pending, size: .large, dimmed: isStale)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The CI runners widget in whatever state `content` is.
/// The screenshot tests construct this directly.
struct CiRunnersFamilyView: View {
    let content: WidgetContent<RunnersData>
    var timeZone: TimeZone = TimeZone.autoupdatingCurrent

    var body: some View {
        FamilyWidgetView(
            kind: .runners,
            size: .small,
            content: content,
            title: "CI runners",
            timeZone: timeZone,
            lastSeen: { (data: RunnersData) -> String in
                "\(data.ci.runnersAlive) alive"
            },
            live: { (data: RunnersData, isStale: Bool) in
                CiRunnersSmallView(data: data, isStale: isStale)
            }
        )
    }
}

struct CiRunnersWidget: Widget {
    let kind: String = "CiRunnersWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: RunnersProvider.staticProvider()
        ) { (entry: FamilyEntry<RunnersData, NoConfiguration>) in
            CiRunnersFamilyView(content: entry.content)
        }
        .configurationDisplayName("CI runners")
        .description("Runners alive and jobs waiting.")
        .supportedFamilies([.systemSmall])
    }
}
