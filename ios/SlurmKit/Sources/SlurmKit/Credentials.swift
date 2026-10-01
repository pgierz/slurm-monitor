import Foundation
import Security

/// Tokens obtained from the OIDC provider.
public struct OIDCTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    /// Expiry of the access token, `nil` when the provider did not state one.
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// What the app holds to authenticate against the middle server.
public enum Credentials: Codable, Sendable, Equatable {
    /// The static token from the server configuration.
    case staticToken(String)
    /// Helmholtz AAI (OIDC) tokens.
    case oidc(OIDCTokens)

    /// The value sent as `Authorization: Bearer …`.
    public var bearerToken: String {
        switch self {
        case .staticToken(let token): return token
        case .oidc(let tokens): return tokens.accessToken
        }
    }
}

/// Storage for the credentials, shared by the app and the widget extension.
public protocol CredentialStoring: Sendable {
    /// Returns the stored credentials, or `nil` when none are stored.
    func load() throws -> Credentials?
    /// Replaces the stored credentials.
    func save(_ credentials: Credentials) throws
    /// Removes the stored credentials.
    func clear() throws
}

/// A keychain call failed with the given status.
public struct KeychainError: Error, Sendable, Equatable {
    public var status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

/// Credentials in the keychain, as one generic password item.
///
/// The item is stored with an access group so the widget extension can read
/// it. When the keychain refuses the access group (unsigned simulator builds,
/// missing entitlement) the store works without one.
public struct KeychainCredentialStore: CredentialStoring {
    public var service: String
    public var account: String
    /// Access group shared with the widget extension; `nil` for none.
    public var accessGroup: String?

    public init(service: String = SlurmKitConstants.keychainService, account: String = "default", accessGroup: String? = SlurmKitConstants.appGroup) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> Credentials? {
        if accessGroup != nil, let found = try? read(group: accessGroup) {
            return try JSONDecoder().decode(Credentials.self, from: found)
        }
        guard let data = try read(group: nil) else { return nil }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    public func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        if accessGroup != nil {
            _ = SecItemDelete(baseQuery(group: accessGroup) as CFDictionary)
            if add(data, group: accessGroup) == errSecSuccess {
                return
            }
        }
        _ = SecItemDelete(baseQuery(group: nil) as CFDictionary)
        let status = add(data, group: nil)
        if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func clear() throws {
        if accessGroup != nil {
            _ = SecItemDelete(baseQuery(group: accessGroup) as CFDictionary)
        }
        let status = SecItemDelete(baseQuery(group: nil) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = group {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    private func read(group: String?) throws -> Data? {
        var query = baseQuery(group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            throw KeychainError(status: status)
        }
        return item as? Data
    }

    private func add(_ data: Data, group: String?) -> OSStatus {
        var query = baseQuery(group: group)
        query[kSecValueData as String] = data
        // Widgets refresh while the device is locked.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil)
    }
}

/// Credentials held in memory, for tests and previews.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Credentials?

    public init(_ credentials: Credentials? = nil) {
        self.stored = credentials
    }

    public func load() throws -> Credentials? {
        lock.withLock { stored }
    }

    public func save(_ credentials: Credentials) throws {
        lock.withLock { stored = credentials }
    }

    public func clear() throws {
        lock.withLock { stored = nil }
    }
}
