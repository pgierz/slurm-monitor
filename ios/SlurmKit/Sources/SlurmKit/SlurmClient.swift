import Foundation

/// What can go wrong when fetching from the middle server.
public enum FetchError: Error, Sendable, Equatable {
    /// Connection failure, timeout, DNS failure, a 5xx answer, or any other unexpected status.
    case unreachable
    /// 401 or 403.
    case unauthorized
    /// No credentials are stored.
    case noCredentials
    /// 503 with `no_data`: the server has not yet completed a first poll.
    case noData
    /// The answer could not be decoded; the text describes why.
    case decoding(String)
    /// No server URL is set.
    case notConfigured
}

/// The five family fetches, as the snapshot loader needs them.
public protocol SlurmFetching: Sendable {
    func queue(partition: String?, user: String?, qos: String?) async throws -> Snapshot<QueueData>
    func nodes(partition: String?) async throws -> Snapshot<NodesData>
    func qos(user: String?) async throws -> Snapshot<QosData>
    func gpu() async throws -> Snapshot<GpuData>
    func runners(user: String?) async throws -> Snapshot<RunnersData>
}

/// Client of the middle server. All methods throw `FetchError`.
///
/// When a call does not name a `user`, the username from the settings is
/// sent, if one is set. Partitions are sent only when given; the default
/// partition from the settings is for the caller to apply.
public struct SlurmClient: SlurmFetching {
    public let settings: ServerSettings
    private let credentials: any CredentialStoring
    private let transport: any HTTPTransport

    public init(settings: ServerSettings, credentials: any CredentialStoring, transport: any HTTPTransport = URLSessionTransport()) {
        self.settings = settings
        self.credentials = credentials
        self.transport = transport
    }

    /// A client with the stored settings, the keychain and `URLSession`.
    public static func live() -> SlurmClient {
        SlurmClient(settings: ServerSettings.load(), credentials: KeychainCredentialStore())
    }

    // MARK: Family endpoints

    public func queue(partition: String? = nil, user: String? = nil, qos: String? = nil) async throws -> Snapshot<QueueData> {
        try await get(WidgetFamilyKind.queue.path, query: [("partition", partition), ("user", user ?? settings.username), ("qos", qos)], authenticated: true)
    }

    public func nodes(partition: String? = nil) async throws -> Snapshot<NodesData> {
        try await get(WidgetFamilyKind.nodes.path, query: [("partition", partition)], authenticated: true)
    }

    public func qos(user: String? = nil) async throws -> Snapshot<QosData> {
        try await get(WidgetFamilyKind.qos.path, query: [("user", user ?? settings.username)], authenticated: true)
    }

    public func gpu() async throws -> Snapshot<GpuData> {
        try await get(WidgetFamilyKind.gpu.path, query: [], authenticated: true)
    }

    public func runners(user: String? = nil) async throws -> Snapshot<RunnersData> {
        try await get(WidgetFamilyKind.runners.path, query: [("user", user ?? settings.username)], authenticated: true)
    }

    // MARK: Other endpoints

    /// `GET /api/v1/health`, without authentication.
    public func health() async throws -> HealthStatus {
        try await get(SlurmKitConstants.apiBasePath + "/health", query: [], authenticated: false)
    }

    /// `GET /api/v1/auth/config`, without authentication.
    public func authConfig() async throws -> AuthConfig {
        try await get(SlurmKitConstants.apiBasePath + "/auth/config", query: [], authenticated: false)
    }

    /// `GET /api/v1/me`.
    public func me() async throws -> Identity {
        try await get(SlurmKitConstants.apiBasePath + "/me", query: [], authenticated: true)
    }

    // MARK: Request construction

    /// Builds the request for a path below the server URL. Query items with
    /// `nil` or empty values are left out.
    public func makeRequest(path: String, query: [(String, String?)], bearerToken: String?) throws -> URLRequest {
        guard let base = settings.serverURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw FetchError.notConfigured
        }
        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.path = basePath + path
        var items: [URLQueryItem] = []
        for (name, value) in query {
            if let value = value, !value.isEmpty {
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else {
            throw FetchError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = SlurmKitConstants.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = bearerToken {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: Internals

    private func get<R: Decodable>(_ path: String, query: [(String, String?)], authenticated: Bool) async throws -> R {
        guard settings.serverURL != nil else {
            throw FetchError.notConfigured
        }
        var stored: Credentials?
        if authenticated {
            let loaded = try? credentials.load()
            guard let found = loaded else {
                throw FetchError.noCredentials
            }
            stored = found
        }
        let request = try makeRequest(path: path, query: query, bearerToken: stored?.bearerToken)
        let (data, status) = try await send(request)

        if status == 401, let current = stored, case .oidc(let tokens) = current, let refreshToken = tokens.refreshToken {
            let renewed = try await refreshTokens(refreshToken)
            try? credentials.save(.oidc(renewed))
            let retry = try makeRequest(path: path, query: query, bearerToken: renewed.accessToken)
            let (retryData, retryStatus) = try await send(retry)
            return try interpret(retryData, status: retryStatus)
        }
        return try interpret(data, status: status)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await transport.send(request)
            return (data, response.statusCode)
        } catch {
            throw FetchError.unreachable
        }
    }

    private struct ErrorBody: Decodable {
        var error: String?
    }

    private func interpret<R: Decodable>(_ data: Data, status: Int) throws -> R {
        if (200..<300).contains(status) {
            do {
                return try SlurmJSON.decode(R.self, from: data)
            } catch {
                throw FetchError.decoding(String(describing: error))
            }
        }
        if status == 401 || status == 403 {
            throw FetchError.unauthorized
        }
        if status == 503, let body = try? JSONDecoder().decode(ErrorBody.self, from: data), body.error == "no_data" {
            throw FetchError.noData
        }
        throw FetchError.unreachable
    }

    /// One refresh: server auth configuration, discovery, token request.
    private func refreshTokens(_ refreshToken: String) async throws -> OIDCTokens {
        let config = try await authConfig()
        guard let oidc = config.oidc else {
            throw FetchError.unauthorized
        }
        let client = OIDCClient(transport: transport)
        do {
            let discovery = try await client.discover(issuer: oidc.issuer)
            return try await client.refresh(refreshToken: refreshToken, discovery: discovery, clientId: oidc.clientId)
        } catch OIDCError.network {
            throw FetchError.unreachable
        } catch {
            throw FetchError.unauthorized
        }
    }
}
