import AppIntents
import SwiftUI
import WidgetKit

/// Reloads the timelines of all widgets without opening the app.
struct RefreshWidgetsIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh widgets" }
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// The refresh button of the header row (medium and larger widgets).
struct RefreshButton: View {
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        Button(intent: RefreshWidgetsIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary(reduced: reduced))
        }
        .buttonStyle(.plain)
    }
}
