import AppIntents
import WidgetKit

/// Configuration of the nodes widget.
struct NodesConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Nodes" }
    static var description: IntentDescription { "Choose the partition whose nodes are shown." }

    /// Partition name; empty means the default partition from the app's
    /// settings, or all partitions when none is set there.
    @Parameter(title: "Partition")
    var partition: String?

    init() {}
}
