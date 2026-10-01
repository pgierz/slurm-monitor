import Foundation

/// The state a widget renders.
public enum WidgetContent<T> {
    /// A fresh snapshot.
    case live(T, generatedAt: Date)
    /// A snapshot the server marked stale, or one older than ten minutes.
    case stale(T, generatedAt: Date)
    /// The server cannot be reached; carries the last cached snapshot, if any.
    case vpnNeeded(last: T?, generatedAt: Date?)
    /// Credentials are missing or were refused.
    case signInNeeded
    /// No server URL is set.
    case notConfigured

    /// The data to show, if the state carries any.
    public var value: T? {
        switch self {
        case .live(let value, _): return value
        case .stale(let value, _): return value
        case .vpnNeeded(let last, _): return last
        case .signInNeeded, .notConfigured: return nil
        }
    }

    /// The time of the snapshot the state carries, if any.
    public var generatedAt: Date? {
        switch self {
        case .live(_, let date): return date
        case .stale(_, let date): return date
        case .vpnNeeded(_, let date): return date
        case .signInNeeded, .notConfigured: return nil
        }
    }

    /// True for `.stale`.
    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    /// Applies a transformation to the carried data, keeping the state.
    public func map<U>(_ transform: (T) -> U) -> WidgetContent<U> {
        switch self {
        case .live(let value, let date): return .live(transform(value), generatedAt: date)
        case .stale(let value, let date): return .stale(transform(value), generatedAt: date)
        case .vpnNeeded(let last, let date): return .vpnNeeded(last: last.map(transform), generatedAt: date)
        case .signInNeeded: return .signInNeeded
        case .notConfigured: return .notConfigured
        }
    }
}

extension WidgetContent: Sendable where T: Sendable {}
extension WidgetContent: Equatable where T: Equatable {}

/// Fetches a snapshot and turns the outcome into the state a widget renders.
///
/// - Success: the snapshot is cached; the result is `.live`, or `.stale` when
///   the envelope says so or the snapshot is older than ten minutes.
/// - `.unreachable`, `.noData`: `.vpnNeeded` with the cached snapshot, if any.
/// - `.unauthorized`, `.noCredentials`: `.signInNeeded`.
/// - `.notConfigured`: `.notConfigured`.
/// - `.decoding`: `.stale` with the cached snapshot if there is one,
///   otherwise `.vpnNeeded` without data.
public struct SnapshotLoader: Sendable {
    private let client: any SlurmFetching
    private let cache: any SnapshotCaching
    private let now: @Sendable () -> Date

    public init(client: any SlurmFetching, cache: any SnapshotCaching, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.cache = cache
        self.now = now
    }

    /// A loader with the stored settings, the keychain, `URLSession` and the file cache.
    public static func live() -> SnapshotLoader {
        SnapshotLoader(client: SlurmClient.live(), cache: FileSnapshotCache())
    }

    /// Queue snapshot; cached per server, partition, user and QOS.
    public func queue(partition: String? = nil, user: UserScope = .configured, qos: String? = nil) async -> WidgetContent<QueueData> {
        var parameters: [String: String?] = userParameters(user)
        parameters.updateValue(partition, forKey: "partition")
        parameters.updateValue(qos, forKey: "qos")
        return await load(key: key(.queue, parameters)) { try await client.queue(partition: partition, user: user, qos: qos) }
    }

    /// Nodes snapshot; cached per server and partition.
    public func nodes(partition: String? = nil) async -> WidgetContent<NodesData> {
        let parameters: [String: String?] = ["partition": partition]
        return await load(key: key(.nodes, parameters)) { try await client.nodes(partition: partition) }
    }

    /// QOS snapshot; cached per server and user.
    public func qos(user: UserScope = .configured) async -> WidgetContent<QosData> {
        await load(key: key(.qos, userParameters(user))) { try await client.qos(user: user) }
    }

    /// GPU snapshot; cached per server.
    public func gpu() async -> WidgetContent<GpuData> {
        await load(key: key(.gpu, [:])) { try await client.gpu() }
    }

    /// Runners snapshot; cached per server and user.
    public func runners(user: UserScope = .configured) async -> WidgetContent<RunnersData> {
        await load(key: key(.runners, userParameters(user))) { try await client.runners(user: user) }
    }

    /// The cache key of a family fetch: the server of the client's settings,
    /// the family and its parameters.
    private func key(_ family: WidgetFamilyKind, _ parameters: [String: String?]) -> String {
        SnapshotCacheKey.make(family: family, parameters: parameters, server: client.settings.serverURL)
    }

    private func userParameters(_ scope: UserScope) -> [String: String?] {
        SnapshotCacheKey.userParameters(scope, settings: client.settings)
    }

    /// The general form: runs `fetch`, caches under `key`, and maps the outcome.
    public func load<T: Codable & Sendable & Equatable>(key: String, fetch: () async throws -> Snapshot<T>) async -> WidgetContent<T> {
        let current = now()
        let failure: FetchError
        do {
            let snapshot = try await fetch()
            if let payload = try? SlurmJSON.encode(snapshot) {
                cache.store(payload, key: key, fetchedAt: current)
            }
            return SnapshotLoader.content(for: snapshot, now: current)
        } catch let error as FetchError {
            failure = error
        } catch {
            failure = .unreachable
        }

        switch failure {
        case .unauthorized, .noCredentials:
            return .signInNeeded
        case .notConfigured:
            return .notConfigured
        case .unreachable, .noData:
            let cached: Snapshot<T>? = cachedSnapshot(key: key)
            return .vpnNeeded(last: cached?.data, generatedAt: cached?.generatedAt)
        case .decoding:
            let cached: Snapshot<T>? = cachedSnapshot(key: key)
            if let cached = cached {
                return .stale(cached.data, generatedAt: cached.generatedAt)
            }
            return .vpnNeeded(last: nil, generatedAt: nil)
        }
    }

    /// The last cached snapshot under the key, if it still decodes.
    public func cachedSnapshot<T: Codable & Sendable & Equatable>(key: String) -> Snapshot<T>? {
        guard let entry = cache.load(key: key) else { return nil }
        return try? SlurmJSON.decode(Snapshot<T>.self, from: entry.payload)
    }

    /// Live or stale, for a snapshot that was fetched successfully.
    public static func content<T: Codable & Sendable & Equatable>(for snapshot: Snapshot<T>, now: Date) -> WidgetContent<T> {
        if isStale(snapshot, now: now) {
            return .stale(snapshot.data, generatedAt: snapshot.generatedAt)
        }
        return .live(snapshot.data, generatedAt: snapshot.generatedAt)
    }

    /// True when the envelope is marked stale or is older than ten minutes.
    public static func isStale<T: Codable & Sendable & Equatable>(_ snapshot: Snapshot<T>, now: Date) -> Bool {
        snapshot.stale || now.timeIntervalSince(snapshot.generatedAt) > SlurmKitConstants.staleAfter
    }
}
