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
        let snapshot = try await makeClient(transport).queue(partition: "mpp", user: "bob", qos: "12h")
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
        _ = try await makeClient(runners).runners(user: "carol")
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

    func testRefreshAndRetryOnceOn401WithOIDC() async throws {
        let gpuBody = TestJSON.envelope(TestJSON.gpu)
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if url == "https://slurm.example.org/api/v1/gpu" {
                return authorization == "Bearer new-access" ? (200, gpuBody) : (401, Data("{\"error\": \"unauthorized\"}".utf8))
            }
            if url == "https://slurm.example.org/api/v1/auth/config" {
                return (200, Data(TestJSON.authConfig.utf8))
            }
            if url == "https://login.example.org/oauth2/.well-known/openid-configuration" {
                return (200, Data("{\"authorization_endpoint\": \"https://login.example.org/oauth2/authz\", \"token_endpoint\": \"https://login.example.org/oauth2/token\"}".utf8))
            }
            if url == "https://login.example.org/oauth2/token" {
                return (200, Data("{\"access_token\": \"new-access\", \"expires_in\": 3600, \"token_type\": \"Bearer\"}".utf8))
            }
            return (404, Data())
        }
        let store = InMemoryCredentialStore(.oidc(OIDCTokens(accessToken: "old-access", refreshToken: "refresh-1", expiresAt: nil)))
        let client = SlurmClient(settings: settings, credentials: store, transport: transport)

        let snapshot = try await client.gpu()
        XCTAssertEqual(snapshot.data.total, 24)

        let urls = transport.requests.map { $0.url?.absoluteString ?? "" }
        XCTAssertEqual(urls, [
            "https://slurm.example.org/api/v1/gpu",
            "https://slurm.example.org/api/v1/auth/config",
            "https://login.example.org/oauth2/.well-known/openid-configuration",
            "https://login.example.org/oauth2/token",
            "https://slurm.example.org/api/v1/gpu",
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
    }

    func testFailedRefreshGivesUnauthorized() async {
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url == "https://slurm.example.org/api/v1/auth/config" {
                return (200, Data(TestJSON.authConfig.utf8))
            }
            if url == "https://login.example.org/oauth2/.well-known/openid-configuration" {
                return (200, Data("{\"authorization_endpoint\": \"https://login.example.org/oauth2/authz\", \"token_endpoint\": \"https://login.example.org/oauth2/token\"}".utf8))
            }
            if url == "https://login.example.org/oauth2/token" {
                return (400, Data("{\"error\": \"invalid_grant\"}".utf8))
            }
            return (401, Data("{\"error\": \"unauthorized\"}".utf8))
        }
        let store = InMemoryCredentialStore(.oidc(OIDCTokens(accessToken: "old-access", refreshToken: "refresh-1", expiresAt: nil)))
        let client = SlurmClient(settings: settings, credentials: store, transport: transport)
        await expectFetchError(.unauthorized) { _ = try await client.gpu() }
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testNoRefreshWithoutRefreshToken() async {
        let transport = answering(401, Data())
        let store = InMemoryCredentialStore(.oidc(OIDCTokens(accessToken: "old-access", refreshToken: nil, expiresAt: nil)))
        let client = SlurmClient(settings: settings, credentials: store, transport: transport)
        await expectFetchError(.unauthorized) { _ = try await client.gpu() }
        XCTAssertEqual(transport.requests.count, 1)
    }
}
