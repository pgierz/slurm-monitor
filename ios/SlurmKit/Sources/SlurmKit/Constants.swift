import Foundation

/// Identifiers shared by the app, the widget extension and this package.
public enum SlurmKitConstants {
    /// Info.plist key under which the app and the widget extension state
    /// their app group (written from `APP_ID_BASE`, see `ios/README.md`).
    public static let appGroupInfoKey = "SlurmMonitorAppGroup"
    /// The app group used when the main bundle does not state one, as in
    /// `swift test`.
    public static let defaultAppGroup = "group.de.awi.slurm-monitor"
    /// App group shared by the app and the widget extension: the value of
    /// `appGroupInfoKey` in the main bundle, or `defaultAppGroup`.
    public static let appGroup: String = SlurmKitConstants.resolveAppGroup(
        fromInfoValue: Bundle.main.object(forInfoDictionaryKey: SlurmKitConstants.appGroupInfoKey)
    )

    /// The app group for a value read from an Info.plist: the value itself
    /// when it is a usable identifier, otherwise `defaultAppGroup`.
    public static func resolveAppGroup(fromInfoValue value: Any?) -> String {
        guard let text = value as? String else { return defaultAppGroup }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded build setting reads `group.$(APP_ID_BASE)`.
        if trimmed.isEmpty || trimmed.contains("$") {
            return defaultAppGroup
        }
        return trimmed
    }
    /// Keychain service name under which credentials are stored.
    public static let keychainService = "de.awi.slurm-monitor.credentials"
    /// Redirect URI of the OIDC authorisation code flow.
    public static let oidcRedirectURI = "de.awi.slurm-monitor:/oauth/callback"
    /// URL scheme of the redirect URI, for `ASWebAuthenticationSession`.
    public static let oidcCallbackScheme = "de.awi.slurm-monitor"
    /// Base path of the middle server API.
    public static let apiBasePath = "/api/v1"
    /// Schema version this package was written against.
    public static let schemaVersion = 1
    /// Request timeout in seconds, short enough for a widget timeline refresh.
    public static let requestTimeout: TimeInterval = 8
    /// A snapshot older than this many seconds is shown as stale.
    public static let staleAfter: TimeInterval = 600
}

/// The single JSON configuration used for everything the server sends.
///
/// Field names are mapped with explicit `CodingKeys` in every model, so no key
/// strategy is set. Dates are ISO 8601 in UTC with whole seconds.
public enum SlurmJSON {
    /// A decoder configured for the contract.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// An encoder producing the same shapes the decoder reads.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Decodes a value sent by the server.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    /// Encodes a value in the contract's JSON form.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }
}

/// The five widget families, each backed by one endpoint.
public enum WidgetFamilyKind: String, Codable, Sendable, CaseIterable {
    case queue
    case nodes
    case qos
    case gpu
    case runners

    /// Endpoint path including the API base path, for example `/api/v1/queue`.
    public var path: String {
        SlurmKitConstants.apiBasePath + "/" + rawValue
    }

    /// Short display title, for example `Queue`.
    public var title: String {
        switch self {
        case .queue: return "Queue"
        case .nodes: return "Nodes"
        case .qos: return "QOS"
        case .gpu: return "GPU"
        case .runners: return "Runners"
        }
    }
}
