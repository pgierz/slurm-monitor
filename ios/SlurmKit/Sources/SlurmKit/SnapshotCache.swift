import Foundation

/// A cached snapshot: the envelope JSON and when it was fetched.
public struct CachedSnapshot: Codable, Sendable, Equatable {
    /// The snapshot envelope as JSON.
    public var payload: Data
    public var fetchedAt: Date

    public init(payload: Data, fetchedAt: Date) {
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

/// Storage for the last successful snapshot per key.
public protocol SnapshotCaching: Sendable {
    /// Stores the envelope JSON under the key, replacing an earlier entry.
    func store(_ payload: Data, key: String, fetchedAt: Date)
    /// Returns the entry stored under the key, if any.
    func load(key: String) -> CachedSnapshot?
    /// Removes every entry.
    func removeAll()
}

/// Builds cache keys from a family and its parameter variant.
public enum SnapshotCacheKey {
    /// `queue` for no parameters, otherwise for example `queue-partition=mpp-user=alice`.
    /// Parameters with `nil` or empty values are left out; the rest are sorted by name.
    public static func make(family: WidgetFamilyKind, parameters: [String: String?] = [:]) -> String {
        var parts: [String] = [family.rawValue]
        for name in parameters.keys.sorted() {
            if let value = parameters[name] ?? nil, !value.isEmpty {
                parts.append(name + "=" + value)
            }
        }
        return parts.joined(separator: "-")
    }
}

/// Snapshots as files, one per key, in the app group container
/// (fallback: the caches directory).
public struct FileSnapshotCache: SnapshotCaching {
    public let directory: URL

    /// Uses the given directory; it is created on first write.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Uses `SnapshotCache` inside the app group container, or inside the
    /// caches directory when the container is unavailable.
    public init() {
        self.directory = FileSnapshotCache.defaultDirectory()
    }

    /// The directory the parameterless initialiser uses.
    public static func defaultDirectory() -> URL {
        let manager = FileManager.default
        let base: URL
        if let container = manager.containerURL(forSecurityApplicationGroupIdentifier: SlurmKitConstants.appGroup) {
            base = container
        } else if let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            base = caches
        } else {
            base = manager.temporaryDirectory
        }
        return base.appendingPathComponent("SnapshotCache", isDirectory: true)
    }

    public func store(_ payload: Data, key: String, fetchedAt: Date) {
        let record = CachedSnapshot(payload: payload, fetchedAt: fetchedAt)
        guard let data = try? SlurmJSON.encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key: key), options: .atomic)
    }

    public func load(key: String) -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(key: key)) else { return nil }
        return try? SlurmJSON.decode(CachedSnapshot.self, from: data)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The file a key is stored in. Characters outside `A–Z a–z 0–9 . _ - =` become `_`.
    public func fileURL(key: String) -> URL {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-=")
        let safe = String(key.map { allowed.contains($0) ? $0 : "_" })
        return directory.appendingPathComponent(safe + ".json", isDirectory: false)
    }
}

/// Snapshots held in memory, for tests and previews.
public final class InMemorySnapshotCache: SnapshotCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: CachedSnapshot] = [:]

    public init() {}

    public func store(_ payload: Data, key: String, fetchedAt: Date) {
        lock.withLock { entries[key] = CachedSnapshot(payload: payload, fetchedAt: fetchedAt) }
    }

    public func load(key: String) -> CachedSnapshot? {
        lock.withLock { entries[key] }
    }

    public func removeAll() {
        lock.withLock { entries.removeAll() }
    }
}
