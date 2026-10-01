import Foundation

/// Where the middle server is and whose jobs count as "mine".
public struct ServerSettings: Codable, Sendable, Equatable {
    /// Base URL of the middle server without the `/api/v1` path, for example `https://slurm.example.org`.
    public var serverURL: URL?
    /// Slurm username sent as `user` when a call does not name one.
    public var username: String?
    /// Partition the widgets preselect; `nil` means all partitions.
    public var defaultPartition: String?

    public init(serverURL: URL? = nil, username: String? = nil, defaultPartition: String? = nil) {
        self.serverURL = serverURL
        self.username = username
        self.defaultPartition = defaultPartition
    }

    /// True when a server URL is set.
    public var isConfigured: Bool { serverURL != nil }

    /// The shared defaults of the app group, or `.standard` when the suite is unavailable.
    public static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: SlurmKitConstants.appGroup) ?? .standard
    }

    /// Reads the settings from the shared defaults.
    public static func load() -> ServerSettings {
        load(from: sharedDefaults())
    }

    /// Reads the settings from the given defaults.
    public static func load(from defaults: UserDefaults) -> ServerSettings {
        let url = defaults.string(forKey: Keys.serverURL).flatMap { parseServerURL($0) }
        return ServerSettings(
            serverURL: url,
            username: nonEmpty(defaults.string(forKey: Keys.username)),
            defaultPartition: nonEmpty(defaults.string(forKey: Keys.defaultPartition))
        )
    }

    /// Writes the settings to the shared defaults.
    public func save() {
        save(to: ServerSettings.sharedDefaults())
    }

    /// Writes the settings to the given defaults. `nil` and empty values remove the key.
    public func save(to defaults: UserDefaults) {
        ServerSettings.set(serverURL?.absoluteString, key: Keys.serverURL, in: defaults)
        ServerSettings.set(username, key: Keys.username, in: defaults)
        ServerSettings.set(defaultPartition, key: Keys.defaultPartition, in: defaults)
    }

    /// Turns user input into a server URL: trims white space, adds `https://`
    /// when no scheme is given, removes trailing slashes. Returns `nil` for
    /// empty or unusable input.
    public static func parseServerURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    private enum Keys {
        static let serverURL = "server_url"
        static let username = "username"
        static let defaultPartition = "default_partition"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func set(_ value: String?, key: String, in defaults: UserDefaults) {
        if let value = nonEmpty(value) {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
