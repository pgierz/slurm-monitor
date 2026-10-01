import AppIntents
import SlurmKit
import WidgetKit

/// Stands in for the configuration of widgets that have none.
struct NoConfiguration {}

/// The timeline entry of every widget: the state to draw and the
/// configuration it was loaded for.
struct FamilyEntry<T, Configuration>: TimelineEntry {
    let date: Date
    let content: WidgetContent<T>
    let configuration: Configuration
}

/// Timeline plumbing shared by all widgets.
enum FamilyTimeline {
    /// Normal refresh interval.
    static let refreshInterval: TimeInterval = 15 * 60
    /// Refresh interval in the "VPN needed" state, so that the widget
    /// recovers soon after the VPN comes up.
    static let vpnRetryInterval: TimeInterval = 5 * 60

    /// When the next refresh is due for the given state.
    static func nextRefresh<T>(after now: Date, content: WidgetContent<T>) -> Date {
        switch content {
        case .vpnNeeded:
            return now.addingTimeInterval(vpnRetryInterval)
        case .live, .stale, .signInNeeded, .notConfigured:
            return now.addingTimeInterval(refreshInterval)
        }
    }

    /// The entry for placeholders and the widget gallery: sample data, shown as live.
    static func sampleEntry<T, Configuration>(_ sample: T, configuration: Configuration) -> FamilyEntry<T, Configuration> {
        FamilyEntry(
            date: Date(),
            content: WidgetContent<T>.live(sample, generatedAt: SampleData.generatedAt),
            configuration: configuration
        )
    }

    /// Loads once with `SnapshotLoader.live()` and returns a timeline with
    /// one entry and the refresh policy `.after(nextRefresh)`.
    static func timeline<T, Configuration>(
        configuration: Configuration,
        fetch: (SnapshotLoader) async -> WidgetContent<T>
    ) async -> Timeline<FamilyEntry<T, Configuration>> {
        let loader = SnapshotLoader.live()
        let content: WidgetContent<T> = await fetch(loader)
        let now = Date()
        let entry = FamilyEntry<T, Configuration>(date: now, content: content, configuration: configuration)
        let next: Date = nextRefresh(after: now, content: content)
        return Timeline(entries: [entry], policy: .after(next))
    }
}

/// Timeline provider for widgets with a configuration intent
/// (`AppIntentConfiguration`).
struct FamilyIntentProvider<T, Intent: WidgetConfigurationIntent>: AppIntentTimelineProvider {
    typealias Entry = FamilyEntry<T, Intent>

    /// Data for the placeholder and the widget gallery.
    let sample: T
    /// Loads the state for a configuration.
    let fetch: (SnapshotLoader, Intent) async -> WidgetContent<T>

    func placeholder(in context: Context) -> FamilyEntry<T, Intent> {
        FamilyTimeline.sampleEntry(sample, configuration: Intent())
    }

    func snapshot(for configuration: Intent, in context: Context) async -> FamilyEntry<T, Intent> {
        FamilyTimeline.sampleEntry(sample, configuration: configuration)
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<FamilyEntry<T, Intent>> {
        let fetch = self.fetch
        return await FamilyTimeline.timeline(configuration: configuration) { (loader: SnapshotLoader) in
            await fetch(loader, configuration)
        }
    }
}

/// Timeline provider for widgets without configuration (`StaticConfiguration`).
struct FamilyStaticProvider<T>: TimelineProvider {
    typealias Entry = FamilyEntry<T, NoConfiguration>

    /// Data for the placeholder and the widget gallery.
    let sample: T
    /// Loads the state.
    let fetch: (SnapshotLoader) async -> WidgetContent<T>

    func placeholder(in context: Context) -> FamilyEntry<T, NoConfiguration> {
        FamilyTimeline.sampleEntry(sample, configuration: NoConfiguration())
    }

    func getSnapshot(in context: Context, completion: @escaping (FamilyEntry<T, NoConfiguration>) -> Void) {
        completion(FamilyTimeline.sampleEntry(sample, configuration: NoConfiguration()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FamilyEntry<T, NoConfiguration>>) -> Void) {
        let fetch = self.fetch
        Task {
            let timeline: Timeline<FamilyEntry<T, NoConfiguration>> = await FamilyTimeline.timeline(
                configuration: NoConfiguration(),
                fetch: fetch
            )
            completion(timeline)
        }
    }
}
