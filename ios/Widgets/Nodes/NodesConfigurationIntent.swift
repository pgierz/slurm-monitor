import AppIntents
import WidgetKit

/// Configuration of the nodes widget.
struct NodesConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Nodes" }
    static var description: IntentDescription { "Choose the partition whose nodes are shown." }

    /// Partition name; empty means all partitions.
    @Parameter(title: "Partition")
    var partition: String?

    init() {}
}
