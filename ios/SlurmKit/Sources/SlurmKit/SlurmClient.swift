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
    /// The credential store could not be used: the keychain is locked (the
    /// device has not been unlocked since it started), or refreshed tokens
    /// could not be saved. Says nothing about whether the sign-in is valid.
    case credentialStore
}

/// Whose jobs count as "mine" in a fetch: the `user` query parameter.
public enum UserScope: Sendable, Equatable {
    /// The username from the settings, if one is set. Without one no `user`
    /// is sent, and the server falls back to the signed-in user, if it knows one.
    case configured
    /// This Slurm username.
    case named(String)
    /// No particular user: the whole cluster's view. Sends `*`.
    case everyone

    /// The `user` value that means "no particular user".
    public static let everyoneValue = "*"

    /// The Slurm username the scope stands for with the given settings;
    /// `nil` for `.everyone`, and for `.configured` without a username.
    public func username(settings: ServerSettings) -> String? {
        switch self {
        case .configured:
            return UserScope.nonEmpty(settings.username)
        case .named(let name):
            return UserScope.nonEmpty(name)
        case .everyone:
            return nil
        }
    }

    /// The value sent as `user`; `nil` when the parameter is left out.
    public func queryValue(settings: ServerSettings) -> String? {
        switch self {
        case .everyone:
            return UserScope.everyoneValue
        case .configured, .named:
            return username(settings: settings)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }
}

/// The five family fetches, as the snapshot loader needs them.
public protocol SlurmFetching: Sendable {
    /// The settings the fetches are made with; the loader derives the cache
    /// identity (server and username) from them.
    var settings: ServerSettings { get }
    func queue(partition: String?, user: UserScope, qos: String?) async throws -> Snapshot<QueueData>
    func nodes(partition: String?) async throws -> Snapshot<NodesData>
    func qos(user: UserScope) async throws -> Snapshot<QosData>
    func gpu() async throws -> Snapshot<GpuData>
    func runners(user: UserScope) async throws -> Snapshot<RunnersData>
}

/// Client of the middle server. All methods throw `FetchError`.
///
/// When an OIDC access token is refused with a 401, the client first looks
/// whether newer tokens have been stored meanwhile and retries with those;
/// otherwise it refreshes once, stores the new tokens and retries once.
/// Refreshes run one at a time, within the process and, through a lock file
/// in the app group container, across the app and the widget extension.
///
/// The `user` of a call is a `UserScope`; the default, `.configured`, sends
/// the username from the settings, if one is set. Partitions are sent only
/// when given; the default partition from the settings is for the caller to
/// apply.
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

    public func queue(partition: String? = nil, user: UserScope = .configured, qos: String? = nil) async throws -> Snapshot<QueueData> {
        try await get(WidgetFamilyKind.queue.path, query: [("partition", partition), ("user", user.queryValue(settings: settings)), ("qos", qos)], authenticated: true)
    }

    public func nodes(partition: String? = nil) async throws -> Snapshot<NodesData> {
        try await get(WidgetFamilyKind.nodes.path, query: [("partition", partition)], authenticated: true)
    }

    public func qos(user: UserScope = .configured) async throws -> Snapshot<QosData> {
        try await get(WidgetFamilyKind.qos.path, query: [("user", user.queryValue(settings: settings))], authenticated: true)
    }

    public func gpu() async throws -> Snapshot<GpuData> {
        try await get(WidgetFamilyKind.gpu.path, query: [], authenticated: true)
    }

    public func runners(user: UserScope = .configured) async throws -> Snapshot<RunnersData> {
        try await get(WidgetFamilyKind.runners.path, query: [("user", user.queryValue(settings: settings))], authenticated: true)
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

    /// Where the lock file of the token refresh lies; `nil` for none. A
    /// property, so that tests can keep clear of the app group container.
    var refreshLockFile: @Sendable () -> URL? = { RefreshFileLock.defaultURL() }

    private func get<R: Decodable>(_ path: String, query: [(String, String?)], authenticated: Bool) async throws -> R {
        guard settings.serverURL != nil else {
            throw FetchError.notConfigured
        }
        guard authenticated else {
            let request = try makeRequest(path: path, query: query, bearerToken: nil)
            let (data, status) = try await send(request)
            return try interpret(data, status: status)
        }

        let stored: Credentials = try loadCredentials()
        let request = try makeRequest(path: path, query: query, bearerToken: stored.bearerToken)
        let (data, status) = try await send(request)
        guard status == 401, case .oidc(let refused) = stored else {
            return try interpret(data, status: status)
        }

        // The access token was refused. Another task or the other process
        // may have renewed it already; otherwise it is renewed here.
        guard let token = try await accessTokenAfterRefusal(of: refused) else {
            return try interpret(data, status: status)
        }
        let retry = try makeRequest(path: path, query: query, bearerToken: token)
        let (retryData, retryStatus) = try await send(retry)
        return try interpret(retryData, status: retryStatus)
    }

    /// The stored credentials. A locked keychain is `.credentialStore`, not
    /// `.noCredentials`: the sign-in is most likely there and only cannot be
    /// read before the first unlock.
    private func loadCredentials() throws -> Credentials {
        let loaded: Credentials?
        do {
            loaded = try credentials.load()
        } catch let error as KeychainError where error.isInteractionNotAllowed {
            throw FetchError.credentialStore
        } catch {
            throw FetchError.noCredentials
        }
        guard let found = loaded else {
            throw FetchError.noCredentials
        }
        return found
    }

    /// The stored bearer token, if it can be read and is not the refused one.
    private func storedToken(otherThan refused: String) -> String? {
        let loaded: Credentials?
        do {
            loaded = try credentials.load()
        } catch {
            return nil
        }
        guard let found = loaded, found.bearerToken != refused else {
            return nil
        }
        return found.bearerToken
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

    // MARK: Token refresh

    /// The access token to retry with after `refused` got a 401, or `nil`
    /// when there is none to try (no refresh token).
    ///
    /// Refreshes run one at a time: within the process behind
    /// `RefreshGate`, across the app and the widget extension behind a lock
    /// file in the app group container. A refresh token can be used once, so
    /// two refreshes with the same one would sign the user out.
    private func accessTokenAfterRefusal(of refused: OIDCTokens) async throws -> String? {
        guard await RefreshGate.shared.acquire() else {
            // Cancelled while waiting; nothing was asked of the provider.
            throw FetchError.unreachable
        }
        let fileLock = RefreshFileLock(url: refreshLockFile())
        await fileLock.lock()

        let outcome: Result<String?, FetchError>
        do {
            let token: String? = try await renewUnderLock(refused)
            outcome = .success(token)
        } catch let error as FetchError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(.unreachable)
        }

        fileLock.unlock()
        await RefreshGate.shared.release()
        return try outcome.get()
    }

    /// The body of a refresh; runs with both locks held.
    private func renewUnderLock(_ refused: OIDCTokens) async throws -> String? {
        // Whoever held the lock before may have stored new tokens.
        let current: Credentials = try loadCredentials()
        if current.bearerToken != refused.accessToken {
            return current.bearerToken
        }
        guard case .oidc(let tokens) = current, let refreshToken = tokens.refreshToken else {
            return nil
        }

        let renewed: OIDCTokens
        do {
            renewed = try await requestNewTokens(tokens, refreshToken: refreshToken)
        } catch {
            // A writer that does not take the lock (a fresh sign-in in the
            // app) may have replaced the tokens meanwhile.
            if let other = storedToken(otherThan: refused.accessToken) {
                return other
            }
            throw error
        }

        do {
            try credentials.save(.oidc(renewed))
        } catch {
            // The old refresh token may be spent and the new one is not
            // stored: say so instead of carrying on as if all were well.
            throw FetchError.credentialStore
        }
        return renewed.accessToken
    }

    /// One token request when the tokens carry their endpoint and client
    /// identifier; otherwise the server's auth configuration and discovery
    /// first. Throws `FetchError`.
    private func requestNewTokens(_ tokens: OIDCTokens, refreshToken: String) async throws -> OIDCTokens {
        let client = OIDCClient(transport: transport)
        if let endpoint = tokens.tokenEndpoint, let clientId = tokens.clientId, !clientId.isEmpty {
            do {
                return try await client.refresh(refreshToken: refreshToken, tokenEndpoint: endpoint, clientId: clientId)
            } catch {
                throw SlurmClient.refreshFailure(error)
            }
        }

        let config = try await authConfig()
        guard let oidc = config.oidc else {
            // The server no longer offers this kind of sign-in.
            throw FetchError.unauthorized
        }
        let discovery: OIDCDiscovery
        do {
            discovery = try await client.discover(issuer: oidc.issuer)
        } catch {
            // Discovery says nothing about the refresh token.
            throw FetchError.unreachable
        }
        do {
            return try await client.refresh(refreshToken: refreshToken, tokenEndpoint: discovery.tokenEndpoint, clientId: oidc.clientId)
        } catch {
            throw SlurmClient.refreshFailure(error)
        }
    }

    /// What a failed token request means: only a 400 or 401 of the token
    /// endpoint says that the refresh token is no good. A network failure, a
    /// 5xx or an unreadable answer is the provider's trouble and leaves the
    /// sign-in as it is.
    static func refreshFailure(_ error: Error) -> FetchError {
        if let oidcError = error as? OIDCError, case .http(let status) = oidcError, status == 400 || status == 401 {
            return .unauthorized
        }
        return .unreachable
    }
}

/// Lets one token refresh run at a time within the process.
actor RefreshGate {
    static let shared = RefreshGate()

    private var held = false

    private func take() -> Bool {
        if held {
            return false
        }
        held = true
        return true
    }

    /// Waits for the gate. Returns false, without holding it, when the task
    /// is cancelled while waiting.
    nonisolated func acquire() async -> Bool {
        while true {
            if await take() {
                return true
            }
            if Task.isCancelled {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func release() {
        held = false
    }
}

/// An advisory lock (`flock`) on a file in the app group container, so that
/// the app and the widget extension do not refresh at the same time.
///
/// Taking it never blocks: it is tried for a bounded time, and when the file
/// cannot be opened (no container, as in unsigned builds and tests) or the
/// lock does not come free, the caller proceeds without it.
final class RefreshFileLock {
    static let fileName = "token-refresh.lock"
    static let attempts = 60
    static let pauseNanoseconds: UInt64 = 100_000_000

    private let url: URL?
    private let attempts: Int
    private var descriptor: Int32 = -1

    init(url: URL?, attempts: Int = RefreshFileLock.attempts) {
        self.url = url
        self.attempts = attempts
    }

    /// The lock file in the app group container; `nil` without a container.
    static func defaultURL() -> URL? {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SlurmKitConstants.appGroup)
        return container?.appendingPathComponent(fileName, isDirectory: false)
    }

    /// True while the lock is held.
    var isHeld: Bool {
        descriptor >= 0
    }

    /// Tries for up to six seconds; gives up at once when the task is cancelled.
    func lock() async {
        guard let url = url, descriptor < 0 else { return }
        let opened: Int32 = open(url.path, O_CREAT | O_RDWR, 0o600)
        if opened < 0 {
            return
        }
        var attempt = 0
        while attempt < attempts {
            if flock(opened, LOCK_EX | LOCK_NB) == 0 {
                descriptor = opened
                return
            }
            if Task.isCancelled {
                break
            }
            try? await Task.sleep(nanoseconds: RefreshFileLock.pauseNanoseconds)
            attempt += 1
        }
        _ = close(opened)
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    deinit {
        if descriptor >= 0 {
            _ = close(descriptor)
        }
    }
}
