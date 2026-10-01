import SlurmKit
import SwiftUI

/// What makes a section load again: changed settings or credentials, or
/// another partition.
struct ReloadKey: Hashable {
    var revision: Int
    var partition: String?
}

/// The frame every data section shares: the snapshot time, pull to refresh,
/// and the notices for the states without usable data.
struct FamilyScaffold<T, Detail: View>: View {
    private let title: String
    private let content: WidgetContent<T>?
    private let reload: () async -> Void
    private let openSettings: () -> Void
    private let detail: (T, Tone) -> Detail

    init(
        title: String,
        content: WidgetContent<T>?,
        reload: @escaping () async -> Void,
        openSettings: @escaping () -> Void,
        @ViewBuilder detail: @escaping (T, Tone) -> Detail
    ) {
        self.title = title
        self.content = content
        self.reload = reload
        self.openSettings = openSettings
        self.detail = detail
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SnapshotTimeRow(text: timeText, highlighted: timeHighlighted)
                stateView
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await reload()
        }
    }

    @ViewBuilder
    private var stateView: some View {
        if let content = content {
            loadedView(content)
        } else {
            LoadingNotice()
        }
    }

    @ViewBuilder
    private func loadedView(_ content: WidgetContent<T>) -> some View {
        switch content {
        case .live(let value, _):
            detail(value, Tone(stale: false))
        case .stale(let value, _):
            detail(value, Tone(stale: true))
        case .vpnNeeded(let last, _):
            NoticeView(
                symbolName: "lock.shield",
                title: "VPN needed",
                message: "The server could not be reached. Connect to the VPN, then pull down to refresh.",
                compact: last != nil
            )
            if let last = last {
                detail(last, Tone(stale: true))
            }
        case .signInNeeded:
            NoticeView(
                symbolName: "key.fill",
                title: "Sign in needed",
                message: "The server answers only to a signed-in user.",
                buttonTitle: "Open Settings",
                action: openSettings
            )
        case .notConfigured:
            NoticeView(
                symbolName: "server.rack",
                title: "Set the server address",
                message: "Enter the address of the Slurm Monitor server in Settings.",
                buttonTitle: "Open Settings",
                action: openSettings
            )
        }
    }

    private var timeText: String {
        guard let content = content else { return Format.dash }
        switch content {
        case .live(_, let date):
            return "snapshot " + Format.clockTime(date, timeZone: .current)
        case .stale(_, let date):
            return Format.asOf(date, timeZone: .current)
        case .vpnNeeded(_, let date):
            guard let date = date else { return Format.dash }
            return "last seen " + Format.clockTime(date, timeZone: .current)
        case .signInNeeded, .notConfigured:
            return Format.dash
        }
    }

    private var timeHighlighted: Bool {
        guard let content = content else { return false }
        switch content {
        case .stale, .vpnNeeded:
            return true
        case .live, .signInNeeded, .notConfigured:
            return false
        }
    }
}

/// The snapshot time, right-aligned above the content.
struct SnapshotTimeRow: View {
    let text: String
    let highlighted: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(highlighted ? Palette.amber : Palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text == Format.dash ? "No snapshot" : text)
    }
}

/// A notice that takes the place of the content.
struct NoticeView: View {
    let symbolName: String
    let title: String
    let message: String
    var buttonTitle: String? = nil
    var action: (() -> Void)? = nil
    var compact: Bool = false

    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: symbolSize))
                .foregroundStyle(Palette.amber)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.primary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let buttonTitle = buttonTitle, let action = action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 20 : 0)
        .frame(maxWidth: .infinity, minHeight: compact ? 0 : 420)
    }
}

private struct LoadingNotice: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading")
                .font(.body)
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

/// The partition filter of the Queue and Nodes sections.
struct PartitionMenu: View {
    @Binding var selection: String?
    let names: [String]

    var body: some View {
        Picker("Partition", selection: $selection) {
            Text("All partitions").tag(String?.none)
            ForEach(names, id: \.self) { name in
                Text(name).tag(String?.some(name))
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Partition filter")
    }
}

#Preview("Notices") {
    ScrollView {
        VStack(spacing: 24) {
            NoticeView(symbolName: "lock.shield", title: "VPN needed",
                       message: "The server could not be reached. Connect to the VPN, then pull down to refresh.",
                       compact: true)
            NoticeView(symbolName: "key.fill", title: "Sign in needed",
                       message: "The server answers only to a signed-in user.",
                       buttonTitle: "Open Settings", action: {}, compact: true)
            NoticeView(symbolName: "server.rack", title: "Set the server address",
                       message: "Enter the address of the Slurm Monitor server in Settings.",
                       buttonTitle: "Open Settings", action: {}, compact: true)
        }
        .padding()
    }
    .background(Palette.background)
    .preferredColorScheme(.dark)
}
