import Foundation
import XCTest
@testable import SlurmKit

final class OIDCTests: XCTestCase {
    private let discovery = OIDCDiscovery(
        authorizationEndpoint: URL(string: "https://login.example.org/oauth2/authz")!,
        tokenEndpoint: URL(string: "https://login.example.org/oauth2/token")!
    )
    private let config = OIDCConfig(issuer: "https://login.example.org/oauth2", clientId: "slurm-monitor-app", scopes: ["openid", "profile"])

    func testChallengeMatchesRFC7636AppendixB() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE(verifier: verifier).challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifier() {
        let first = PKCE.generate()
        let second = PKCE.generate()
        XCTAssertEqual(first.verifier.count, 43)
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertEqual(first.challenge, PKCE.challenge(for: first.verifier))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(first.verifier.allSatisfy { allowed.contains($0) })
    }

    func testDiscoveryURL() {
        XCTAssertEqual(OIDCClient.discoveryURL(issuer: "https://login.example.org/oauth2")?.absoluteString, "https://login.example.org/oauth2/.well-known/openid-configuration")
        XCTAssertEqual(OIDCClient.discoveryURL(issuer: "https://login.example.org/oauth2/")?.absoluteString, "https://login.example.org/oauth2/.well-known/openid-configuration")
        XCTAssertNil(OIDCClient.discoveryURL(issuer: " "))
    }

    func testAuthorizationURL() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = try XCTUnwrap(OIDCClient.authorizationURL(discovery: discovery, config: config, pkce: pkce, state: "state-1"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "login.example.org")
        XCTAssertEqual(components.path, "/oauth2/authz")
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value
        }
        XCTAssertEqual(values, [
            "response_type": "code",
            "client_id": "slurm-monitor-app",
            "redirect_uri": "de.awi.slurm-monitor:/oauth/callback",
            "scope": "openid profile",
            "state": "state-1",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
        ])
    }

    func testAuthorizationURLAsksForConsentWithOfflineAccess() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let offline = OIDCConfig(issuer: config.issuer, clientId: config.clientId, scopes: ["openid", "profile", "offline_access"])
        let url = try XCTUnwrap(OIDCClient.authorizationURL(discovery: discovery, config: offline, pkce: pkce, state: "state-1"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let prompts: [String?] = items.filter { $0.name == "prompt" }.map { $0.value }
        XCTAssertEqual(prompts, ["consent"])
        XCTAssertEqual(items.first(where: { $0.name == "scope" })?.value, "openid profile offline_access")

        // Without the scope no prompt is asked for.
        let plain = try XCTUnwrap(OIDCClient.authorizationURL(discovery: discovery, config: config, pkce: pkce, state: "state-1"))
        let plainItems = URLComponents(url: plain, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(plainItems.contains(where: { $0.name == "prompt" }))
    }

    func testAuthorizationCodeFromCallback() throws {
        let good = URL(string: "de.awi.slurm-monitor:/oauth/callback?code=abc&state=state-1")!
        XCTAssertEqual(try OIDCClient.authorizationCode(fromCallback: good, expectedState: "state-1"), "abc")

        XCTAssertThrowsError(try OIDCClient.authorizationCode(fromCallback: good, expectedState: "other")) { error in
            XCTAssertEqual(error as? OIDCError, .stateMismatch)
        }
        let denied = URL(string: "de.awi.slurm-monitor:/oauth/callback?error=access_denied&state=state-1")!
        XCTAssertThrowsError(try OIDCClient.authorizationCode(fromCallback: denied, expectedState: "state-1")) { error in
            XCTAssertEqual(error as? OIDCError, .authorizationFailed("access_denied"))
        }
        let explained = URL(string: "de.awi.slurm-monitor:/oauth/callback?error=access_denied&error_description=Not+a+member%20of%20the+group&state=state-1")!
        XCTAssertThrowsError(try OIDCClient.authorizationCode(fromCallback: explained, expectedState: "state-1")) { error in
            XCTAssertEqual(error as? OIDCError, .authorizationFailed("access_denied: Not a member of the group"))
        }
        let empty = URL(string: "de.awi.slurm-monitor:/oauth/callback?state=state-1")!
        XCTAssertThrowsError(try OIDCClient.authorizationCode(fromCallback: empty, expectedState: "state-1")) { error in
            XCTAssertEqual(error as? OIDCError, .missingCode)
        }
    }

    func testFormEncoding() {
        XCTAssertEqual(OIDCClient.formEncode([("a", "b c"), ("redirect_uri", "de.awi.slurm-monitor:/oauth/callback"), ("x", "1+2&3=4")]), "a=b%20c&redirect_uri=de.awi.slurm-monitor%3A%2Foauth%2Fcallback&x=1%2B2%263%3D4")
    }

    func testPrepareAndCompleteAuthorization() async throws {
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url == "https://login.example.org/oauth2/.well-known/openid-configuration" {
                return (200, Data("{\"issuer\": \"https://login.example.org/oauth2\", \"authorization_endpoint\": \"https://login.example.org/oauth2/authz\", \"token_endpoint\": \"https://login.example.org/oauth2/token\"}".utf8))
            }
            if url == "https://login.example.org/oauth2/token" {
                return (200, Data("{\"access_token\": \"access-1\", \"refresh_token\": \"refresh-1\", \"expires_in\": 3600}".utf8))
            }
            return (404, Data())
        }
        let client = OIDCClient(transport: transport)
        let request = try await client.prepareAuthorization(config: config)
        XCTAssertEqual(request.discovery, OIDCDiscovery(authorizationEndpoint: discovery.authorizationEndpoint, tokenEndpoint: discovery.tokenEndpoint, issuer: "https://login.example.org/oauth2"))
        XCTAssertTrue(request.url.absoluteString.hasPrefix("https://login.example.org/oauth2/authz?response_type=code&client_id=slurm-monitor-app"))
        XCTAssertFalse(request.state.isEmpty)

        let callback = try XCTUnwrap(URL(string: "de.awi.slurm-monitor:/oauth/callback?code=the-code&state=" + request.state))
        let now = Date(timeIntervalSince1970: 1_790_857_927)
        let tokens = try await client.completeAuthorization(request, callbackURL: callback, now: now)
        // The tokens remember where to refresh and for which client.
        XCTAssertEqual(tokens, OIDCTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: now.addingTimeInterval(3600), tokenEndpoint: discovery.tokenEndpoint, clientId: "slurm-monitor-app"))

        let tokenRequest = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(tokenRequest.httpMethod, "POST")
        let form = String(decoding: tokenRequest.httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(form, "grant_type=authorization_code&code=the-code&redirect_uri=de.awi.slurm-monitor%3A%2Foauth%2Fcallback&client_id=slurm-monitor-app&code_verifier=" + request.pkce.verifier)
    }

    func testRefreshKeepsOrReplacesTheRefreshToken() async throws {
        let rotating = StubTransport { _ in (200, Data("{\"access_token\": \"a2\", \"refresh_token\": \"r2\"}".utf8)) }
        let rotated = try await OIDCClient(transport: rotating).refresh(refreshToken: "r1", discovery: discovery, clientId: "slurm-monitor-app")
        XCTAssertEqual(rotated, OIDCTokens(accessToken: "a2", refreshToken: "r2", expiresAt: nil, tokenEndpoint: discovery.tokenEndpoint, clientId: "slurm-monitor-app"))

        let direct = try await OIDCClient(transport: rotating).refresh(refreshToken: "r1", tokenEndpoint: discovery.tokenEndpoint, clientId: "slurm-monitor-app")
        XCTAssertEqual(direct, rotated)
        XCTAssertEqual(rotating.requests.last?.url, discovery.tokenEndpoint)

        let keeping = StubTransport { _ in (200, Data("{\"access_token\": \"a2\"}".utf8)) }
        let kept = try await OIDCClient(transport: keeping).refresh(refreshToken: "r1", discovery: discovery, clientId: "slurm-monitor-app")
        XCTAssertEqual(kept.refreshToken, "r1")
    }

    func testDiscoveryMustNameTheConfiguredIssuer() async throws {
        func document(issuer: String?) -> Data {
            let issuerField = issuer.map { "\"issuer\": \"\($0)\", " } ?? ""
            return Data("{\(issuerField)\"authorization_endpoint\": \"https://login.example.org/oauth2/authz\", \"token_endpoint\": \"https://login.example.org/oauth2/token\"}".utf8)
        }
        func discover(_ stated: String?, configured: String) async throws -> OIDCDiscovery {
            let body = document(issuer: stated)
            let transport = StubTransport { _ in (200, body) }
            return try await OIDCClient(transport: transport).discover(issuer: configured)
        }

        // A trailing slash on either side makes no difference.
        let plain = try await discover("https://login.example.org/oauth2", configured: "https://login.example.org/oauth2/")
        XCTAssertEqual(plain.tokenEndpoint, discovery.tokenEndpoint)
        let slashed = try await discover("https://login.example.org/oauth2/", configured: "https://login.example.org/oauth2")
        XCTAssertEqual(slashed.issuer, "https://login.example.org/oauth2/")

        for stated in ["https://elsewhere.example.org/oauth2", "https://login.example.org", nil] {
            do {
                _ = try await discover(stated, configured: "https://login.example.org/oauth2")
                XCTFail("Expected an error for \(stated ?? "no issuer")")
            } catch {
                XCTAssertEqual(error as? OIDCError, .invalidConfiguration)
            }
        }

        XCTAssertEqual(OIDCClient.normalisedIssuer(" https://login.example.org/oauth2// "), "https://login.example.org/oauth2")
        XCTAssertFalse(OIDCClient.issuerMatches(discovery, configured: "https://login.example.org/oauth2"))
    }

    func testStoredCredentialsOfEarlierVersionsStillLoad() throws {
        // As written before the token endpoint and the client identifier were kept.
        let legacy = Data("{\"oidc\":{\"_0\":{\"accessToken\":\"a\",\"refreshToken\":\"r\",\"expiresAt\":0}}}".utf8)
        let decoded = try JSONDecoder().decode(Credentials.self, from: legacy)
        guard case .oidc(let tokens) = decoded else {
            return XCTFail("Expected OIDC credentials")
        }
        XCTAssertEqual(tokens.accessToken, "a")
        XCTAssertEqual(tokens.refreshToken, "r")
        XCTAssertNil(tokens.tokenEndpoint)
        XCTAssertNil(tokens.clientId)

        let bare = Data("{\"oidc\":{\"_0\":{\"accessToken\":\"a\"}}}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(Credentials.self, from: bare), .oidc(OIDCTokens(accessToken: "a", refreshToken: nil, expiresAt: nil)))

        let full = Credentials.oidc(OIDCTokens(accessToken: "a", refreshToken: "r", expiresAt: nil, tokenEndpoint: discovery.tokenEndpoint, clientId: "slurm-monitor-app"))
        XCTAssertEqual(try JSONDecoder().decode(Credentials.self, from: JSONEncoder().encode(full)), full)
    }

    func testAppGroupFromInfoValue() {
        XCTAssertEqual(SlurmKitConstants.resolveAppGroup(fromInfoValue: "group.org.example.monitor"), "group.org.example.monitor")
        XCTAssertEqual(SlurmKitConstants.resolveAppGroup(fromInfoValue: nil), SlurmKitConstants.defaultAppGroup)
        XCTAssertEqual(SlurmKitConstants.resolveAppGroup(fromInfoValue: ""), SlurmKitConstants.defaultAppGroup)
        XCTAssertEqual(SlurmKitConstants.resolveAppGroup(fromInfoValue: "group.$(APP_ID_BASE)"), SlurmKitConstants.defaultAppGroup)
        XCTAssertEqual(SlurmKitConstants.resolveAppGroup(fromInfoValue: 7), SlurmKitConstants.defaultAppGroup)
        // `swift test` has no such key in its main bundle.
        XCTAssertFalse(SlurmKitConstants.appGroup.isEmpty)
    }

    func testErrors() async {
        let refusing = StubTransport { _ in (400, Data("{\"error\": \"invalid_grant\"}".utf8)) }
        do {
            _ = try await OIDCClient(transport: refusing).refresh(refreshToken: "r1", discovery: discovery, clientId: "c")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? OIDCError, .http(400))
        }

        let failing = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await OIDCClient(transport: failing).discover(issuer: "https://login.example.org/oauth2")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? OIDCError, .network)
        }
    }
}
