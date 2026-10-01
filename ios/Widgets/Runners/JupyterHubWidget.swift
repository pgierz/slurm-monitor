import SlurmKit
import SwiftUI
import WidgetKit

/// Small: the session count, footer with the GPU and near-walltime counts.
struct JupyterHubSmallView: View {
    let data: RunnersData
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            FigureView(value: "\(data.jupyterhub.sessions)", label: "sessions", colour: Theme.running, size: .large, dimmed: isStale, accent: true)
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Hairline()
                .padding(.bottom, Theme.Spacing.footerGap - 3)
            RunnersFooterLine(label: "with a GPU", value: "\(data.jupyterhub.withGpu)", dimmed: isStale)
            RunnersFooterLine(label: "near walltime", value: "\(data.jupyterhub.nearWalltime)", valueColour: Theme.pending, dimmed: isStale)
        }
    }
}

/// The JupyterHub widget in whatever state `content` is.
/// The screenshot tests construct this directly.
struct JupyterHubFamilyView: View {
    let content: WidgetContent<RunnersData>
    var timeZone: TimeZone = TimeZone.autoupdatingCurrent

    var body: some View {
        FamilyWidgetView(
            kind: .runners,
            size: .small,
            content: content,
            title: "JupyterHub",
            timeZone: timeZone,
            lastSeen: { (data: RunnersData) -> String in
                "\(data.jupyterhub.sessions) sessions"
            },
            live: { (data: RunnersData, isStale: Bool) in
                JupyterHubSmallView(data: data, isStale: isStale)
            }
        )
    }
}

struct JupyterHubWidget: Widget {
    let kind: String = "JupyterHubWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: RunnersProvider.staticProvider()
        ) { (entry: FamilyEntry<RunnersData, NoConfiguration>) in
            JupyterHubFamilyView(content: entry.content)
        }
        .configurationDisplayName("JupyterHub")
        .description("Sessions running, with a GPU, and near their walltime.")
        .supportedFamilies([.systemSmall])
    }
}
