import Foundation
import XCTest
@testable import SlurmKit

final class ClientTests: XCTestCase {
    private let settings = ServerSettings(serverURL: URL(string: "https://slurm.example.org"), username: "alice", defaultPartition: nil)

    private func makeClient(_ transport: StubTransport, settings: ServerSettings? = nil, credentials: Credentials? = .staticToken("secret")) -> SlurmClient {
        SlurmClient(settings: settings ?? self.settings, credentials: InMemoryCredentialStore(credentials), transport: transport)
    }

    private func answering(_ status: Int, _ body: Data) -> StubTransport {
        StubTransport { _ in (status, body) }
    }

    private func expectFetchError(_ expected: FetchError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as FetchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    func testQueueRequest() async throws {
        let transport = answering(200, TestJSON.envelope(TestJSON.queue))
        let snapshot = try await makeClient(transport).queue(partition: "mpp", user: .named("bob"), qos: "12h")
        XCTAssertEqual(snapshot.data.running, 412)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://slurm.example.org/api/v1/queue?partition=mpp&user=bob&qos=12h")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 8)
    }

    func testUserDefaultsToTheSettingsUsername() async throws {
        let transport = answering(200, TestJSON.envelope(TestJSON.queue))
        _ = try await makeClient(transport).queue()
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/queue?user=alice")
    }

    private func queryItems(_ transport: StubTransport) throws -> [URLQueryItem] {
        let url = try XCTUnwrap(transport.requests.first?.url)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    func testEveryoneSendsAStar() async throws {
        let star = URLQueryItem(name: "user", value: "*")
        let queue = answering(200, TestJSON.envelope(TestJSON.queue))
        _ = try await makeClient(queue).queue(partition: "mpp", user: .everyone)
        XCTAssertEqual(try queryItems(queue), [URLQueryItem(name: "partition", value: "mpp"), star])

        let qos = answering(200, TestJSON.envelope(TestJSON.qos))
        _ = try await makeClient(qos).qos(user: .everyone)
        XCTAssertEqual(try queryItems(qos), [star])

        // Also without a username in the settings.
        let bare = ServerSettings(serverURL: URL(string: "https://slurm.example.org"), username: nil, defaultPartition: nil)
        let runners = answering(200, TestJSON.envelope(TestJSON.runners))
        _ = try await makeClient(runners, settings: bare).runners(user: .everyone)
        XCTAssertEqual(try queryItems(runners), [star])
    }

    func testUserScopeValues() {
        let bare = ServerSettings(serverURL: nil, username: nil, defaultPartition: nil)
        XCTAssertEqual(UserScope.configured.queryValue(settings: settings), "alice")
        XCTAssertNil(UserScope.configured.queryValue(settings: bare))
        XCTAssertEqual(UserScope.named("bob").queryValue(settings: settings), "bob")
        XCTAssertNil(UserScope.named("").queryValue(settings: settings))
        XCTAssertEqual(UserScope.everyone.queryValue(settings: settings), "*")
        XCTAssertEqual(UserScope.everyone.queryValue(settings: bare), UserScope.everyoneValue)
        XCTAssertNil(UserScope.everyone.username(settings: settings))
        XCTAssertEqual(UserScope.configured.username(settings: settings), "alice")
    }

    func testNoQueryWithoutParameters() async throws {
        let transport = answering(200, TestJSON.envelope(TestJSON.queue))
        let bare = ServerSettings(serverURL: URL(string: "https://slurm.example.org"), username: nil, defaultPartition: "mpp")
        _ = try await makeClient(transport, settings: bare).queue()
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/queue")
    }

    func testOtherFamilyRequests() async throws {
        let nodes = answering(200, TestJSON.envelope(TestJSON.nodes))
        _ = try await makeClient(nodes).nodes(partition: "gpu")
        XCTAssertEqual(nodes.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/nodes?partition=gpu")

        let allNodes = answering(200, TestJSON.envelope(TestJSON.nodes))
        _ = try await makeClient(allNodes).nodes()
        XCTAssertEqual(allNodes.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/nodes")

        let qos = answering(200, TestJSON.envelope(TestJSON.qos))
        _ = try await makeClient(qos).qos()
        XCTAssertEqual(qos.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/qos?user=alice")

        let gpu = answering(200, TestJSON.envelope(TestJSON.gpu))
        _ = try await makeClient(gpu).gpu()
        XCTAssertEqual(gpu.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/gpu")

        let runners = answering(200, TestJSON.envelope(TestJSON.runners))
        _ = try await makeClient(runners).runners(user: .named("carol"))
        XCTAssertEqual(runners.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/runners?user=carol")
    }

    func testBasePathOfTheServerURLIsKept() async throws {
        let transport = answering(200, TestJSON.envelope(TestJSON.gpu))
        let prefixed = ServerSettings(serverURL: URL(string: "https://slurm.example.org/monitor/"), username: nil, defaultPartition: nil)
        _ = try await makeClient(transport, settings: prefixed).gpu()
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://slurm.example.org/monitor/api/v1/gpu")
    }

    func testUnauthenticatedEndpointsSendNoToken() async throws {
        let health = answering(200, Data(TestJSON.health.utf8))
        let status = try await makeClient(health, credentials: nil).health()
        XCTAssertEqual(status.status, "ok")
        XCTAssertEqual(health.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/health")
        XCTAssertNil(health.requests.first?.value(forHTTPHeaderField: "Authorization"))

        let config = answering(200, Data(TestJSON.authConfig.utf8))
        let auth = try await makeClient(config, credentials: nil).authConfig()
        XCTAssertEqual(auth.oidc?.clientId, "slurm-monitor-app")
        XCTAssertEqual(config.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/auth/config")
        XCTAssertNil(config.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testMe() async throws {
        let transport = answering(200, Data(TestJSON.me.utf8))
        let identity = try await makeClient(transport).me()
        XCTAssertEqual(identity.username, "pgierz")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://slurm.example.org/api/v1/me")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testNotConfiguredAndNoCredentials() async {
        let transport = answering(200, TestJSON.envelope(TestJSON.gpu))
        await expectFetchError(.notConfigured) {
            _ = try await self.makeClient(transport, settings: ServerSettings()).gpu()
        }
        await expectFetchError(.noCredentials) {
            _ = try await self.makeClient(transport, credentials: nil).gpu()
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testStatusMapping() async {
        let unauthorized = answering(401, Data("{\"error\": \"unauthorized\"}".utf8))
        await expectFetchError(.unauthorized) { _ = try await self.makeClient(unauthorized).gpu() }
        XCTAssertEqual(unauthorized.requests.count, 1)

        let forbidden = answering(403, Data("{\"error\": \"forbidden\"}".utf8))
        await expectFetchError(.unauthorized) { _ = try await self.makeClient(forbidden).gpu() }

        let noData = answering(503, Data("{\"error\": \"no_data\"}".utf8))
        await expectFetchError(.noData) { _ = try await self.makeClient(noData).gpu() }

        let unavailable = answering(503, Data("<html>Service Unavailable</html>".utf8))
        await expectFetchError(.unreachable) { _ = try await self.makeClient(unavailable).gpu() }

        let gateway = answering(502, Data())
        await expectFetchError(.unreachable) { _ = try await self.makeClient(gateway).gpu() }

        let failing = StubTransport { _ in throw URLError(.timedOut) }
        await expectFetchError(.unreachable) { _ = try await self.makeClient(failing).gpu() }
    }

    func testDecodingFailure() async {
        let transport = answering(200, Data("{\"schema_version\": 1}".utf8))
        do {
            _ = try await makeClient(transport).gpu()
            XCTFail("Expected a decoding error")
        } catch let error as FetchError {
            if case .decoding = error {
                // expected
            } else {
                XCTFail("Unexpected \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: Token refresh

    private static let gpuURL = "https://slurm.example.org/api/v1/gpu"
    private static let authConfigURL = "https://slurm.example.org/api/v1/auth/config"
    private static let discoveryURL = "https://login.example.org/oauth2/.well-known/openid-configuration"
    private static let tokenURL = "https://login.example.org/oauth2/token"
    private static let refusal = Data("{\"error\": \"unauthorized\"}".utf8)

    private func oldTokens(withEndpoint: Bool = false) -> OIDCTokens {
        OIDCTokens(
            accessToken: "old-access",
            refreshToken: "refresh-1",
            expiresAt: nil,
            tokenEndpoint: withEndpoint ? URL(string: ClientTests.tokenURL) : nil,
            clientId: withEndpoint ? "slurm-monitor-app" : nil
        )
    }

    /// A client for the refresh tests; it keeps clear of the app group container.
    private func refreshClient(_ transport: StubTransport, store: any CredentialStoring) -> SlurmClient {
        var client = SlurmClient(settings: settings, credentials: store, transport: transport)
        client.refreshLockFile = { nil }
        return client
    }

    /// The server accepts only `accepted`; the provider answers the token
    /// request with `token`.
    private func refreshTransport(accepted: String = "new-access", token: @escaping @Sendable () throws -> (Int, Data)) -> StubTransport {
        let gpuBody = TestJSON.envelope(TestJSON.gpu)
        return StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url == ClientTests.gpuURL {
                let authorization = request.value(forHTTPHeaderField: "Authorization")
                return authorization == "Bearer " + accepted ? (200, gpuBody) : (401, ClientTests.refusal)
            }
            if url == ClientTests.authConfigURL {
                return (200, Data(TestJSON.authConfig.utf8))
            }
            if url == ClientTests.discoveryURL {
                return (200, Data(TestJSON.discovery.utf8))
            }
            if url == ClientTests.tokenURL {
                return try token()
            }
            return (404, Data())
        }
    }

    private static let newTokenAnswer = Data("{\"access_token\": \"new-access\", \"expires_in\": 3600, \"token_type\": \"Bearer\"}".utf8)

    private func urls(_ transport: StubTransport) -> [String] {
        transport.requests.map { $0.url?.absoluteString ?? "" }
    }

    func testRefreshAndRetryOnceOn401WithOIDC() async throws {
        let transport = refreshTransport { (200, ClientTests.newTokenAnswer) }
        let store = InMemoryCredentialStore(.oidc(oldTokens()))
        let client = refreshClient(transport, store: store)

        let snapshot = try await client.gpu()
        XCTAssertEqual(snapshot.data.total, 24)

        // Credentials stored before the endpoint was kept: discovery first.
        XCTAssertEqual(urls(transport), [
            ClientTests.gpuURL,
            ClientTests.authConfigURL,
            ClientTests.discoveryURL,
            ClientTests.tokenURL,
            ClientTests.gpuURL,
        ])
        let tokenRequest = transport.requests[3]
        XCTAssertEqual(tokenRequest.httpMethod, "POST")
        XCTAssertEqual(tokenRequest.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let form = String(decoding: tokenRequest.httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(form, "grant_type=refresh_token&refresh_token=refresh-1&client_id=slurm-monitor-app")

        guard case .oidc(let saved)? = try store.load() else {
            return XCTFail("Expected OIDC credentials")
        }
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-1")
        XCTAssertNotNil(saved.expiresAt)
        // The next refresh needs no discovery.
        XCTAssertEqual(saved.tokenEndpoint?.absoluteString, ClientTests.tokenURL)
        XCTAssertEqual(saved.clientId, "slurm-monitor-app")
    }

    func testRefreshWithStoredEndpointNeedsOneRequest() async throws {
        let transport = refreshTransport { (200, ClientTests.newTokenAnswer) }
        let store = InMemoryCredentialStore(.oidc(oldTokens(withEndpoint: true)))
        let client = refreshClient(transport, store: store)

        _ = try await client.gpu()
        XCTAssertEqual(urls(transport), [ClientTests.gpuURL, ClientTests.tokenURL, ClientTests.gpuURL])
        let form = String(decoding: transport.requests[1].httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(form, "grant_type=refresh_token&refresh_token=refresh-1&client_id=slurm-monitor-app")
        guard case .oidc(let saved)? = try store.load() else {
            return XCTFail("Expected OIDC credentials")
        }
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.tokenEndpoint?.absoluteString, ClientTests.tokenURL)
        XCTAssertEqual(saved.clientId, "slurm-monitor-app")
    }

    func testTokensStoredMeanwhileAreUsedInsteadOfRefreshing() async throws {
        let transport = refreshTransport { (500, Data()) }
        let newer = OIDCTokens(accessToken: "new-access", refreshToken: "refresh-2", expiresAt: nil)
        // First read: the old tokens. Second read, before refreshing: newer ones.
        let store = SequenceCredentialStore([.oidc(oldTokens(withEndpoint: true)), .oidc(newer)])
        let client = refreshClient(transport, store: store)

        let snapshot = try await client.gpu()
        XCTAssertEqual(snapshot.data.total, 24)
        XCTAssertEqual(urls(transport), [ClientTests.gpuURL, ClientTests.gpuURL])
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertTrue(store.savedCredentials.isEmpty)
    }

    func testTokensStoredDuringAFailedRefreshAreUsed() async throws {
        let transport = refreshTransport { (400, Data("{\"error\": \"invalid_grant\"}".utf8)) }
        let newer = OIDCTokens(accessToken: "new-access", refreshToken: "refresh-2", expiresAt: nil)
        // Old tokens for the request and before the refresh; newer ones after it failed.
        let old: Credentials = .oidc(oldTokens(withEndpoint: true))
        let store = SequenceCredentialStore([old, old, .oidc(newer)])
        let client = refreshClient(transport, store: store)

        let snapshot = try await client.gpu()
        XCTAssertEqual(snapshot.data.total, 24)
        XCTAssertEqual(urls(transport), [ClientTests.gpuURL, ClientTests.tokenURL, ClientTests.gpuURL])
        XCTAssertEqual(store.loadCount, 3)
        XCTAssertTrue(store.savedCredentials.isEmpty)
    }

    func testConcurrentRefusalsRefreshOnce() async throws {
        let transport = refreshTransport { (200, ClientTests.newTokenAnswer) }
        let store = InMemoryCredentialStore(.oidc(oldTokens(withEndpoint: true)))
        let client = refreshClient(transport, store: store)

        async let first = client.gpu()
        async let second = client.gpu()
        async let third = client.gpu()
        let totals = try await [first.data.total, second.data.total, third.data.total]
        XCTAssertEqual(totals, [24, 24, 24])
        let tokenRequests = urls(transport).filter { $0 == ClientTests.tokenURL }
        XCTAssertEqual(tokenRequests.count, 1)
    }

    func testFailedRefreshGivesUnauthorized() async {
        let transport = refreshTransport(accepted: "never") { (400, Data("{\"error\": \"invalid_grant\"}".utf8)) }
        let store = InMemoryCredentialStore(.oidc(oldTokens()))
        let client = refreshClient(transport, store: store)
        await expectFetchError(.unauthorized) { _ = try await client.gpu() }
        XCTAssertEqual(transport.requests.count, 4)

        let refused = refreshTransport(accepted: "never") { (401, Data()) }
        let direct = refreshClient(refused, store: InMemoryCredentialStore(.oidc(oldTokens(withEndpoint: true))))
        await expectFetchError(.unauthorized) { _ = try await direct.gpu() }
        XCTAssertEqual(refused.requests.count, 2)
    }

    func testProviderTroubleDuringRefreshGivesUnreachable() async {
        let failures: [@Sendable () throws -> (Int, Data)] = [
            { (500, Data()) },
            { (503, Data("<html>busy</html>".utf8)) },
            { (200, Data("not json".utf8)) },
            { throw URLError(.timedOut) },
            { (403, Data()) },
        ]
        for failure in failures {
            let transport = refreshTransport(accepted: "never", token: failure)
            let store = InMemoryCredentialStore(.oidc(oldTokens(withEndpoint: true)))
            let client = refreshClient(transport, store: store)
            await expectFetchError(.unreachable) { _ = try await client.gpu() }
            // The stored sign-in is left as it was.
            let kept: Credentials? = try? store.load()
            XCTAssertEqual(kept, Credentials.oidc(oldTokens(withEndpoint: true)))
        }
    }

    func testRefreshFailureMapping() {
        XCTAssertEqual(SlurmClient.refreshFailure(OIDCError.http(400)), .unauthorized)
        XCTAssertEqual(SlurmClient.refreshFailure(OIDCError.http(401)), .unauthorized)
        XCTAssertEqual(SlurmClient.refreshFailure(OIDCError.http(403)), .unreachable)
        XCTAssertEqual(SlurmClient.refreshFailure(OIDCError.http(502)), .unreachable)
        XCTAssertEqual(SlurmClient.refreshFailure(OIDCError.network), .unreachable)
        XCTAssertEqual(SlurmClient.refreshFailure(OIDCError.decoding("bad")), .unreachable)
        XCTAssertEqual(SlurmClient.refreshFailure(OIDCError.invalidConfiguration), .unreachable)
        XCTAssertEqual(SlurmClient.refreshFailure(URLError(.badURL)), .unreachable)
    }

    func testDiscoveryNamingAnotherIssuerIsNotUsedForRefresh() async {
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url == ClientTests.authConfigURL {
                return (200, Data(TestJSON.authConfig.utf8))
            }
            if url == ClientTests.discoveryURL {
                return (200, Data("{\"issuer\": \"https://elsewhere.example.org\", \"authorization_endpoint\": \"https://elsewhere.example.org/authz\", \"token_endpoint\": \"https://elsewhere.example.org/token\"}".utf8))
            }
            return (401, ClientTests.refusal)
        }
        let client = refreshClient(transport, store: InMemoryCredentialStore(.oidc(oldTokens())))
        await expectFetchError(.unreachable) { _ = try await client.gpu() }
        XCTAssertFalse(urls(transport).contains("https://elsewhere.example.org/token"))
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testFailedSaveOfRefreshedTokensIsReported() async {
        let transport = refreshTransport { (200, ClientTests.newTokenAnswer) }
        let store = SequenceCredentialStore([.oidc(oldTokens(withEndpoint: true))], saveError: KeychainError(status: -25299))
        let client = refreshClient(transport, store: store)
        await expectFetchError(.credentialStore) { _ = try await client.gpu() }
        XCTAssertEqual(urls(transport), [ClientTests.gpuURL, ClientTests.tokenURL])
    }

    func testLockedKeychainIsNotASignOut() async {
        let transport = answering(200, TestJSON.envelope(TestJSON.gpu))
        // errSecInteractionNotAllowed: not unlocked since the device started.
        let locked = KeychainError(status: -25308)
        XCTAssertTrue(locked.isInteractionNotAllowed)
        let lockedClient = SlurmClient(settings: settings, credentials: FailingCredentialStore(error: locked), transport: transport)
        await expectFetchError(.credentialStore) { _ = try await lockedClient.gpu() }

        let broken = KeychainError(status: -50)
        XCTAssertFalse(broken.isInteractionNotAllowed)
        let brokenClient = SlurmClient(settings: settings, credentials: FailingCredentialStore(error: broken), transport: transport)
        await expectFetchError(.noCredentials) { _ = try await brokenClient.gpu() }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testNoRefreshWithoutRefreshToken() async {
        let transport = answering(401, Data())
        let store = InMemoryCredentialStore(.oidc(OIDCTokens(accessToken: "old-access", refreshToken: nil, expiresAt: nil)))
        let client = refreshClient(transport, store: store)
        await expectFetchError(.unauthorized) { _ = try await client.gpu() }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testNoRefreshForAStaticToken() async {
        let transport = answering(401, Data())
        let client = refreshClient(transport, store: InMemoryCredentialStore(.staticToken("secret")))
        await expectFetchError(.unauthorized) { _ = try await client.gpu() }
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: Locks

    func testRefreshGateAdmitsOneAtATime() async {
        let gate = RefreshGate()
        let first = await gate.acquire()
        XCTAssertTrue(first)
        let waiter = Task { await gate.acquire() }
        // A cancelled waiter gives up without holding the gate.
        waiter.cancel()
        let cancelled = await waiter.value
        XCTAssertFalse(cancelled)
        await gate.release()
        let second = await gate.acquire()
        XCTAssertTrue(second)
        await gate.release()
    }

    func testRefreshFileLock() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SlurmKitTests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(RefreshFileLock.fileName, isDirectory: false)

        let first = RefreshFileLock(url: file)
        await first.lock()
        XCTAssertTrue(first.isHeld)

        // A second holder waits its bounded time and then goes without.
        let second = RefreshFileLock(url: file, attempts: 2)
        await second.lock()
        XCTAssertFalse(second.isHeld)

        first.unlock()
        XCTAssertFalse(first.isHeld)
        await second.lock()
        XCTAssertTrue(second.isHeld)
        second.unlock()

        // No container, or a file that cannot be opened: no lock, no failure.
        let none = RefreshFileLock(url: nil)
        await none.lock()
        XCTAssertFalse(none.isHeld)
        none.unlock()
        let missing = RefreshFileLock(url: directory.appendingPathComponent("absent/lock", isDirectory: false))
        await missing.lock()
        XCTAssertFalse(missing.isHeld)
    }
}
