import AppIntents
import WidgetKit

/// Whose jobs count as "mine" in the queue widget.
enum QueueScope: String, AppEnum {
    /// The user from the app's settings (or the signed-in identity).
    case mine
    /// No user is sent; the widget shows the totals only.
    case everyone

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Jobs"
    static var caseDisplayRepresentations: [QueueScope: DisplayRepresentation] = [
        .mine: "Mine",
        .everyone: "Everyone",
    ]
}

/// Configuration of the queue widget.
struct QueueConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Queue" }
    static var description: IntentDescription { "Choose the partition and whose jobs are counted." }

    /// Partition name; empty means the default partition from the app's
    /// settings, or all partitions when none is set there.
    @Parameter(title: "Partition")
    var partition: String?

    @Parameter(title: "Jobs", default: .mine)
    var scope: QueueScope

    init() {}
}
