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
    /// The longest a family load may take. The system gives a timeline
    /// provider limited time; a load that overruns it leaves the widget
    /// with nothing new at all.
    static let loadDeadline: TimeInterval = 20

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

    // MARK: Staleness between reloads

    /// When live content turns stale: `generatedAt` plus
    /// `SlurmKitConstants.staleAfter`, if that lies after `now`. `nil` for
    /// content that is not live or is past that time already.
    static func staleDate<T>(for content: WidgetContent<T>, after now: Date) -> Date? {
        guard case .live(_, let generatedAt) = content else { return nil }
        let date: Date = generatedAt.addingTimeInterval(SlurmKitConstants.staleAfter)
        return date > now ? date : nil
    }

    /// The content as it is to be shown at `date`: live content whose
    /// snapshot is `staleAfter` old by then becomes stale, all else stays.
    static func content<T>(_ content: WidgetContent<T>, at date: Date) -> WidgetContent<T> {
        guard case .live(let value, let generatedAt) = content else { return content }
        if date >= generatedAt.addingTimeInterval(SlurmKitConstants.staleAfter) {
            return WidgetContent<T>.stale(value, generatedAt: generatedAt)
        }
        return content
    }

    /// The entries of one load: the content now and, when it is live, a
    /// second entry at the moment it turns stale, so that the widget does
    /// not show an old snapshot as fresh until the next reload.
    static func entries<T, Configuration>(
        for content: WidgetContent<T>,
        configuration: Configuration,
        now: Date
    ) -> [FamilyEntry<T, Configuration>] {
        var result: [FamilyEntry<T, Configuration>] = [
            FamilyEntry<T, Configuration>(date: now, content: content, configuration: configuration)
        ]
        if let staleAt = staleDate(for: content, after: now) {
            result.append(
                FamilyEntry<T, Configuration>(
                    date: staleAt,
                    content: FamilyTimeline.content(content, at: staleAt),
                    configuration: configuration
                )
            )
        }
        return result
    }

    // MARK: Loading within a deadline

    /// Runs `operation` and returns its result, or `nil` when it has not
    /// finished after `seconds`. The operation is cancelled then; it must
    /// give way to cancellation, as the network calls of SlurmKit do.
    static func withDeadline<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let nanoseconds: UInt64 = UInt64(max(0.0, seconds) * 1_000_000_000)
        return await withTaskGroup(of: Optional<Value>.self, returning: Optional<Value>.self) { group in
            group.addTask {
                let value: Value = await operation()
                return Optional<Value>.some(value)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return Optional<Value>.none
            }
            var first: Value? = nil
            if let finished = await group.next() {
                first = finished
            }
            group.cancelAll()
            return first
        }
    }

    /// One family load, bounded by `deadline` seconds. When the time runs
    /// out the answer is what the cache holds, as "VPN needed".
    static func load<T: Sendable>(
        loader: SnapshotLoader,
        deadline: TimeInterval = FamilyTimeline.loadDeadline,
        fetch: @escaping @Sendable (SnapshotLoader) async -> WidgetContent<T>
    ) async -> WidgetContent<T> {
        let finished: WidgetContent<T>? = await withDeadline(seconds: deadline) {
            await fetch(loader)
        }
        if let finished = finished {
            return finished
        }
        return await fetch(loader.cachedOnly())
    }

    /// Loads once with `SnapshotLoader.live()`, within the deadline, and
    /// returns a timeline with the entry for now, the entry at which live
    /// content turns stale, and the refresh policy `.after(nextRefresh)`.
    static func timeline<T: Sendable, Configuration>(
        configuration: Configuration,
        fetch: @escaping @Sendable (SnapshotLoader) async -> WidgetContent<T>
    ) async -> Timeline<FamilyEntry<T, Configuration>> {
        let content: WidgetContent<T> = await load(loader: SnapshotLoader.live(), fetch: fetch)
        let now = Date()
        let entries: [FamilyEntry<T, Configuration>] = FamilyTimeline.entries(for: content, configuration: configuration, now: now)
        let next: Date = nextRefresh(after: now, content: content)
        return Timeline(entries: entries, policy: .after(next))
    }

    // MARK: Gallery and transient snapshots

    /// What the cache holds for a family, as content to show at `now`;
    /// `nil` when nothing is cached. Never asks the server.
    static func cachedContent<T>(
        now: Date,
        fetch: (SnapshotLoader) async -> WidgetContent<T>
    ) async -> WidgetContent<T>? {
        let cached: WidgetContent<T> = await fetch(SnapshotLoader.live().cachedOnly())
        guard let value = cached.value, let generatedAt = cached.generatedAt else {
            return nil
        }
        return FamilyTimeline.content(WidgetContent<T>.live(value, generatedAt: generatedAt), at: now)
    }

    /// The entry for `snapshot`: sample data in the widget gallery
    /// (`isPreview`), otherwise the cached snapshot if there is one, and
    /// sample data if not.
    static func snapshotEntry<T, Configuration>(
        sample: T,
        configuration: Configuration,
        isPreview: Bool,
        fetch: (SnapshotLoader) async -> WidgetContent<T>
    ) async -> FamilyEntry<T, Configuration> {
        if isPreview {
            return sampleEntry(sample, configuration: configuration)
        }
        let now = Date()
        guard let cached = await cachedContent(now: now, fetch: fetch) else {
            return sampleEntry(sample, configuration: configuration)
        }
        return FamilyEntry<T, Configuration>(date: now, content: cached, configuration: configuration)
    }
}

/// Timeline provider for widgets with a configuration intent
/// (`AppIntentConfiguration`).
struct FamilyIntentProvider<T: Sendable, Intent: WidgetConfigurationIntent>: AppIntentTimelineProvider {
    typealias Entry = FamilyEntry<T, Intent>

    /// Data for the placeholder and the widget gallery.
    let sample: T
    /// Loads the state for a configuration.
    let fetch: @Sendable (SnapshotLoader, Intent) async -> WidgetContent<T>

    func placeholder(in context: Context) -> FamilyEntry<T, Intent> {
        FamilyTimeline.sampleEntry(sample, configuration: Intent())
    }

    func snapshot(for configuration: Intent, in context: Context) async -> FamilyEntry<T, Intent> {
        let fetch = self.fetch
        return await FamilyTimeline.snapshotEntry(
            sample: sample,
            configuration: configuration,
            isPreview: context.isPreview
        ) { (loader: SnapshotLoader) in
            await fetch(loader, configuration)
        }
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<FamilyEntry<T, Intent>> {
        let fetch = self.fetch
        return await FamilyTimeline.timeline(configuration: configuration) { (loader: SnapshotLoader) in
            await fetch(loader, configuration)
        }
    }
}

/// Timeline provider for widgets without configuration (`StaticConfiguration`).
struct FamilyStaticProvider<T: Sendable>: TimelineProvider {
    typealias Entry = FamilyEntry<T, NoConfiguration>

    /// Data for the placeholder and the widget gallery.
    let sample: T
    /// Loads the state.
    let fetch: @Sendable (SnapshotLoader) async -> WidgetContent<T>

    func placeholder(in context: Context) -> FamilyEntry<T, NoConfiguration> {
        FamilyTimeline.sampleEntry(sample, configuration: NoConfiguration())
    }

    func getSnapshot(in context: Context, completion: @escaping (FamilyEntry<T, NoConfiguration>) -> Void) {
        if context.isPreview {
            completion(FamilyTimeline.sampleEntry(sample, configuration: NoConfiguration()))
            return
        }
        let fetch = self.fetch
        let sample: T = self.sample
        Task {
            let entry: FamilyEntry<T, NoConfiguration> = await FamilyTimeline.snapshotEntry(
                sample: sample,
                configuration: NoConfiguration(),
                isPreview: false,
                fetch: fetch
            )
            completion(entry)
        }
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
