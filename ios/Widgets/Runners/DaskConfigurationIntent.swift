import AppIntents
import WidgetKit

/// Whose Dask clusters the widget lists.
enum DaskScope: String, AppEnum {
    /// The user from the app's settings (or the signed-in identity).
    case mine
    /// No user is sent; all clusters are listed.
    case everyone

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Clusters"
    static var caseDisplayRepresentations: [DaskScope: DisplayRepresentation] = [
        .mine: "Mine",
        .everyone: "Everyone",
    ]
}

/// Configuration of the Dask widget.
struct DaskConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Dask clusters" }
    static var description: IntentDescription { "Choose whose clusters are listed." }

    @Parameter(title: "Clusters", default: .everyone)
    var scope: DaskScope

    init() {}
}
