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
    var body: some View {
        Button(intent: RefreshWidgetsIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
        }
        .buttonStyle(.plain)
    }
}
