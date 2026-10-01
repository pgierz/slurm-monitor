import CryptoKit
import Foundation

/// A PKCE code verifier with its S256 challenge (RFC 7636).
public struct PKCE: Sendable, Equatable {
    public var verifier: String
    public var challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// A fresh verifier from 32 random bytes.
    public static func generate() -> PKCE {
        PKCE(verifier: randomURLSafeString(byteCount: 32))
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))` without padding.
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// Random bytes in base64url form without padding; also used for `state`.
    public static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return base64URL(Data(bytes))
    }

    /// Base64url without padding.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The parts of the provider's discovery document this package uses.
public struct OIDCDiscovery: Codable, Sendable, Equatable {
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL

    public init(authorizationEndpoint: URL, tokenEndpoint: URL) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
    }
}

/// Everything the app needs to run and finish one sign-in.
public struct OIDCAuthorizationRequest: Sendable, Equatable {
    /// The URL to open in `ASWebAuthenticationSession`.
    public var url: URL
    /// The `state` value the callback must repeat.
    public var state: String
    public var pkce: PKCE
    public var discovery: OIDCDiscovery
    public var config: OIDCConfig

    public init(url: URL, state: String, pkce: PKCE, discovery: OIDCDiscovery, config: OIDCConfig) {
        self.url = url
        self.state = state
        self.pkce = pkce
        self.discovery = discovery
        self.config = config
    }
}

/// Failures of the OIDC flow.
public enum OIDCError: Error, Sendable, Equatable {
    /// The issuer or an endpoint is not a usable URL.
    case invalidConfiguration
    /// The provider could not be reached.
    case network
    /// The provider answered with this HTTP status.
    case http(Int)
    /// The provider's answer could not be read.
    case decoding(String)
    /// The callback's `state` does not match the request.
    case stateMismatch
    /// The callback carries no `code`.
    case missingCode
    /// The provider reported an error in the callback, for example `access_denied`.
    case authorizationFailed(String)
}

/// The OIDC authorisation code flow with PKCE for a public client, without UI.
public struct OIDCClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// The discovery document URL, `{issuer}/.well-known/openid-configuration`.
    public static func discoveryURL(issuer: String) -> URL? {
        var trimmed = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.isEmpty { return nil }
        return URL(string: trimmed + "/.well-known/openid-configuration")
    }

    /// Fetches the discovery document of the issuer.
    public func discover(issuer: String) async throws -> OIDCDiscovery {
        guard let url = OIDCClient.discoveryURL(issuer: issuer) else {
            throw OIDCError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = SlurmKitConstants.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request, as: OIDCDiscovery.self)
    }

    /// Builds the authorisation URL. Pure; no network access.
    public static func authorizationURL(discovery: OIDCDiscovery, config: OIDCConfig, pkce: PKCE, state: String, redirectURI: String = SlurmKitConstants.oidcRedirectURI) -> URL? {
        guard var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "client_id", value: config.clientId))
        items.append(URLQueryItem(name: "redirect_uri", value: redirectURI))
        items.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")))
        items.append(URLQueryItem(name: "state", value: state))
        items.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
        items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        components.queryItems = items
        return components.url
    }

    /// Discovers the endpoints and prepares a sign-in with fresh PKCE and state values.
    public func prepareAuthorization(config: OIDCConfig) async throws -> OIDCAuthorizationRequest {
        let discovery = try await discover(issuer: config.issuer)
        let pkce = PKCE.generate()
        let state = PKCE.randomURLSafeString(byteCount: 16)
        guard let url = OIDCClient.authorizationURL(discovery: discovery, config: config, pkce: pkce, state: state) else {
            throw OIDCError.invalidConfiguration
        }
        return OIDCAuthorizationRequest(url: url, state: state, pkce: pkce, discovery: discovery, config: config)
    }

    /// Reads the authorisation code from the callback URL and checks the state.
    public static func authorizationCode(fromCallback callbackURL: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        if let error = value("error") {
            throw OIDCError.authorizationFailed(error)
        }
        guard value("state") == expectedState else {
            throw OIDCError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw OIDCError.missingCode
        }
        return code
    }

    /// Finishes a sign-in: takes the callback URL handed over by
    /// `ASWebAuthenticationSession` and exchanges its code for tokens.
    public func completeAuthorization(_ request: OIDCAuthorizationRequest, callbackURL: URL, now: Date = Date()) async throws -> OIDCTokens {
        let code = try OIDCClient.authorizationCode(fromCallback: callbackURL, expectedState: request.state)
        return try await exchangeCode(code, verifier: request.pkce.verifier, discovery: request.discovery, clientId: request.config.clientId, now: now)
    }

    /// Exchanges an authorisation code for tokens.
    public func exchangeCode(_ code: String, verifier: String, discovery: OIDCDiscovery, clientId: String, redirectURI: String = SlurmKitConstants.oidcRedirectURI, now: Date = Date()) async throws -> OIDCTokens {
        let response = try await postForm(to: discovery.tokenEndpoint, fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientId),
            ("code_verifier", verifier),
        ])
        return response.tokens(now: now, previousRefreshToken: nil)
    }

    /// Obtains new tokens from a refresh token. When the provider does not
    /// issue a new refresh token, the old one is kept.
    public func refresh(refreshToken: String, discovery: OIDCDiscovery, clientId: String, now: Date = Date()) async throws -> OIDCTokens {
        let response = try await postForm(to: discovery.tokenEndpoint, fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientId),
        ])
        return response.tokens(now: now, previousRefreshToken: refreshToken)
    }

    /// Encodes fields as `application/x-www-form-urlencoded`.
    public static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func escape(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        }
        return fields.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }

        func tokens(now: Date, previousRefreshToken: String?) -> OIDCTokens {
            OIDCTokens(
                accessToken: accessToken,
                refreshToken: refreshToken ?? previousRefreshToken,
                expiresAt: expiresIn.map { now.addingTimeInterval($0) }
            )
        }
    }

    private func postForm(to url: URL, fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = SlurmKitConstants.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(OIDCClient.formEncode(fields).utf8)
        return try await perform(request, as: TokenResponse.self)
    }

    private func perform<R: Decodable>(_ request: URLRequest, as type: R.Type) async throws -> R {
        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.send(request)
        } catch {
            throw OIDCError.network
        }
        guard (200..<300).contains(result.1.statusCode) else {
            throw OIDCError.http(result.1.statusCode)
        }
        do {
            return try JSONDecoder().decode(type, from: result.0)
        } catch {
            throw OIDCError.decoding(String(describing: error))
        }
    }
}
