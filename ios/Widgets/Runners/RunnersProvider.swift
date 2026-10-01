import SlurmKit
import SwiftUI
import WidgetKit

/// Whose Dask clusters the runners snapshot lists. The CI and JupyterHub
/// figures do not depend on it.
enum RunnersScope {
    /// The user from the app's settings (or the signed-in identity).
    case mine
    /// No particular user; all clusters are listed.
    case everyone
}

/// The provider side shared by the three runner widgets: one fetch, one
/// sample, and the two timeline providers built from them.
enum RunnersProvider {
    /// Loads the runners family. "mine" leaves the user to the client (the
    /// username from the settings, or the signed-in user); "everyone" asks
    /// for no particular user and is cached under its own key, so the
    /// widgets without a scope share one snapshot.
    static func fetch(loader: SnapshotLoader, scope: RunnersScope) async -> WidgetContent<RunnersData> {
        switch scope {
        case .mine:
            return await loader.runners(user: UserScope.configured)
        case .everyone:
            return await loader.runners(user: UserScope.everyone)
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
