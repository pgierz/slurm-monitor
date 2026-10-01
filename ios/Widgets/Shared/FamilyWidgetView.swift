import SlurmKit
import SwiftUI
import WidgetKit

/// The container every Home Screen widget is built from.
///
/// It draws the header row, chooses between the live layout and the state
/// views, forces the dark colour scheme, sets the widget background and the
/// deep link into the app. The `live` closure draws only the body below the
/// header; its second argument is true when the snapshot is stale and is to
/// be passed on as `dimmed`.
struct FamilyWidgetView<T, Live: View>: View {
    let kind: WidgetFamilyKind
    let size: WidgetLayoutSize
    let content: WidgetContent<T>
    /// Header title of the state views, and of the live layout unless `liveTitle` is given.
    let title: String
    /// Header title built from the data, for example "My jobs · 12 R · 3 PD".
    let liveTitle: ((T) -> String)?
    let timeZone: TimeZone
    /// Key figures for the "last seen" footer of "VPN needed".
    let lastSeen: (T) -> String
    let live: (T, Bool) -> Live

    init(
        kind: WidgetFamilyKind,
        size: WidgetLayoutSize,
        content: WidgetContent<T>,
        title: String,
        liveTitle: ((T) -> String)? = nil,
        timeZone: TimeZone = TimeZone.current,
        lastSeen: @escaping (T) -> String,
        @ViewBuilder live: @escaping (T, Bool) -> Live
    ) {
        self.kind = kind
        self.size = size
        self.content = content
        self.title = title
        self.liveTitle = liveTitle
        self.timeZone = timeZone
        self.lastSeen = lastSeen
        self.live = live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.headerGap) {
            header
            stateBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .containerBackground(for: .widget) {
            Theme.background
        }
        .widgetURL(WidgetLinks.family(kind))
    }

    private var header: some View {
        WidgetHeader(
            title: headerTitle,
            time: headerTime,
            timeIsStale: content.isStale,
            showsRefresh: size != .small
        )
    }

    @ViewBuilder
    private var stateBody: some View {
        switch content {
        case .live(let value, _):
            live(value, false)
        case .stale(let value, _):
            live(value, true)
        case .vpnNeeded(let last, _):
            VpnNeededView(size: size, lastSeen: lastSeenText(last))
        case .signInNeeded:
            SignInNeededView(size: size)
        case .notConfigured:
            NotConfiguredView(size: size)
        }
    }

    private func lastSeenText(_ last: T?) -> String? {
        guard let last = last else { return nil }
        return lastSeen(last)
    }

    private var headerTitle: String {
        switch content {
        case .live(let value, _):
            return dataTitle(value)
        case .stale(let value, _):
            return dataTitle(value)
        case .vpnNeeded, .signInNeeded, .notConfigured:
            return title
        }
    }

    private func dataTitle(_ value: T) -> String {
        if let liveTitle = liveTitle {
            return liveTitle(value)
        }
        return title
    }

    private var headerTime: String {
        switch content {
        case .live(_, let date):
            return Format.clockTime(date, timeZone: timeZone)
        case .stale(_, let date):
            return Format.asOf(date, timeZone: timeZone)
        case .vpnNeeded(_, let date):
            guard let date = date else { return Format.dash }
            return Format.clockTime(date, timeZone: timeZone)
        case .signInNeeded, .notConfigured:
            return Format.dash
        }
    }
}
