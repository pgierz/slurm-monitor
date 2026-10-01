import SlurmKit
import SwiftUI
import WidgetKit

/// Whose Dask clusters the runners snapshot lists. The CI and JupyterHub
/// figures do not depend on it.
enum RunnersScope {
    /// The user from the app's settings (or the signed-in identity).
    case mine
    /// No user is sent; all clusters are listed.
    case everyone
}

/// The provider side shared by the three runner widgets: one fetch, one
/// sample, and the two timeline providers built from them.
enum RunnersProvider {
    /// Loads the runners family. "mine" leaves the user to the client (the
    /// username from the settings); "everyone" sends none and caches under
    /// its own key, so the widgets without a scope share one snapshot.
    static func fetch(loader: SnapshotLoader, scope: RunnersScope) async -> WidgetContent<RunnersData> {
        switch scope {
        case .mine:
            return await loader.runners()
        case .everyone:
            let client = SlurmClient.live()
            let parameters: [String: String?] = ["scope": "everyone"]
            let key: String = SnapshotCacheKey.make(family: .runners, parameters: parameters)
            // An empty user is dropped from the query, where nil would be
            // replaced by the username from the settings.
            return await loader.load(key: key) {
                try await client.runners(user: "")
            }
        }
    }

    /// For the widgets without configuration (CI, JupyterHub).
    static func fetchEveryone(loader: SnapshotLoader) async -> WidgetContent<RunnersData> {
        await fetch(loader: loader, scope: .everyone)
    }

    /// For the Dask widget, whose configuration chooses the scope.
    static func fetchDask(loader: SnapshotLoader, configuration: DaskConfigurationIntent) async -> WidgetContent<RunnersData> {
        switch configuration.scope {
        case .mine:
            return await fetch(loader: loader, scope: .mine)
        case .everyone:
            return await fetch(loader: loader, scope: .everyone)
        }
    }

    static func staticProvider() -> FamilyStaticProvider<RunnersData> {
        FamilyStaticProvider<RunnersData>(
            sample: SampleData.runners.data,
            fetch: RunnersProvider.fetchEveryone(loader:)
        )
    }

    static func daskProvider() -> FamilyIntentProvider<RunnersData, DaskConfigurationIntent> {
        FamilyIntentProvider<RunnersData, DaskConfigurationIntent>(
            sample: SampleData.runners.data,
            fetch: RunnersProvider.fetchDask(loader:configuration:)
        )
    }
}

/// One footer line of a runner widget: label left, value right, no hairline.
struct RunnersFooterLine: View {
    let label: String
    let value: String
    var valueColour: Color = Theme.primaryText
    var dimmed: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(Theme.footerValueFont)
                .foregroundStyle(Theme.figure(valueColour, dimmed: dimmed))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
