import Foundation
import XCTest
@testable import SlurmKit

final class LoaderTests: XCTestCase {
    private let generatedAt = SampleData.generatedAt
    /// The tag of the server in `StubFetcher.settings`.
    private let serverTag = SnapshotCacheKey.serverTag(URL(string: "https://slurm.example.org")!)

    private func makeLoader(_ fetcher: StubFetcher, cache: InMemorySnapshotCache = InMemorySnapshotCache(), secondsAfterSnapshot: TimeInterval = 60) -> SnapshotLoader {
        let now = generatedAt.addingTimeInterval(secondsAfterSnapshot)
        return SnapshotLoader(client: fetcher, cache: cache, now: { now })
    }

    func testFreshSnapshotIsLiveAndCached() async {
        let fetcher = StubFetcher()
        fetcher.gpuResult = .success(SampleData.gpu)
        let cache = InMemorySnapshotCache()
        let content = await makeLoader(fetcher, cache: cache).gpu()
        XCTAssertEqual(content, .live(SampleData.gpu.data, generatedAt: generatedAt))
        XCTAssertFalse(content.isStale)
        XCTAssertNil(cache.load(key: "gpu"))
        let entry = cache.load(key: serverTag + "-gpu")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.fetchedAt, generatedAt.addingTimeInterval(60))
    }

    func testStaleFlagGivesStale() async {
        let fetcher = StubFetcher()
        var snapshot = SampleData.nodes
        snapshot.stale = true
        fetcher.nodesResult = .success(snapshot)
        let content = await makeLoader(fetcher).nodes()
        XCTAssertEqual(content, .stale(SampleData.nodes.data, generatedAt: generatedAt))
        XCTAssertTrue(content.isStale)
    }

    func testOldSnapshotGivesStale() async {
        let fetcher = StubFetcher()
        fetcher.qosResult = .success(SampleData.qos)
        let atLimit = await makeLoader(fetcher, secondsAfterSnapshot: 600).qos()
        XCTAssertEqual(atLimit, .live(SampleData.qos.data, generatedAt: generatedAt))
        let beyond = await makeLoader(fetcher, secondsAfterSnapshot: 601).qos()
        XCTAssertEqual(beyond, .stale(SampleData.qos.data, generatedAt: generatedAt))
    }

    func testUnreachableWithoutCacheGivesVpnNeededWithoutData() async {
        let fetcher = StubFetcher()
        fetcher.queueResult = .failure(.unreachable)
        let content = await makeLoader(fetcher).queue()
        XCTAssertEqual(content, .vpnNeeded(last: nil, generatedAt: nil))
        XCTAssertNil(content.value)
    }

    func testUnreachableWithCacheGivesVpnNeededWithLastSnapshot() async {
        let fetcher = StubFetcher()
        let cache = InMemorySnapshotCache()
        fetcher.queueResult = .success(SampleData.queue)
        _ = await makeLoader(fetcher, cache: cache).queue()
        fetcher.queueResult = .failure(.unreachable)
        let content = await makeLoader(fetcher, cache: cache, secondsAfterSnapshot: 3600).queue()
        XCTAssertEqual(content, .vpnNeeded(last: SampleData.queue.data, generatedAt: generatedAt))
        XCTAssertEqual(content.value?.running, 412)
        XCTAssertEqual(content.generatedAt, generatedAt)
    }

    func testNoDataGivesVpnNeeded() async {
        let fetcher = StubFetcher()
        fetcher.runnersResult = .failure(.noData)
        let content = await makeLoader(fetcher).runners()
        XCTAssertEqual(content, .vpnNeeded(last: nil, generatedAt: nil))
    }

    func testUnauthorizedAndNoCredentialsGiveSignInNeeded() async {
        let fetcher = StubFetcher()
        let cache = InMemorySnapshotCache()
        fetcher.gpuResult = .success(SampleData.gpu)
        _ = await makeLoader(fetcher, cache: cache).gpu()

        fetcher.gpuResult = .failure(.unauthorized)
        let refused = await makeLoader(fetcher, cache: cache).gpu()
        XCTAssertEqual(refused, .signInNeeded)

        fetcher.gpuResult = .failure(.noCredentials)
        let missing = await makeLoader(fetcher, cache: cache).gpu()
        XCTAssertEqual(missing, .signInNeeded)
        XCTAssertNil(missing.value)
    }

    func testNotConfigured() async {
        let fetcher = StubFetcher()
        fetcher.nodesResult = .failure(.notConfigured)
        let content = await makeLoader(fetcher).nodes()
        XCTAssertEqual(content, .notConfigured)
    }

    func testDecodingFailureFallsBackToCache() async {
        let fetcher = StubFetcher()
        let cache = InMemorySnapshotCache()
        fetcher.qosResult = .failure(.decoding("bad"))
        let without = await makeLoader(fetcher, cache: cache).qos()
        XCTAssertEqual(without, .vpnNeeded(last: nil, generatedAt: nil))

        fetcher.qosResult = .success(SampleData.qos)
        _ = await makeLoader(fetcher, cache: cache).qos()
        fetcher.qosResult = .failure(.decoding("bad"))
        let with = await makeLoader(fetcher, cache: cache).qos()
        XCTAssertEqual(with, .stale(SampleData.qos.data, generatedAt: generatedAt))
    }

    func testCacheIsKeptPerParameterVariant() async {
        let fetcher = StubFetcher()
        let cache = InMemorySnapshotCache()
        fetcher.nodesResult = .success(SampleData.nodes)
        _ = await makeLoader(fetcher, cache: cache).nodes(partition: "mpp")
        XCTAssertNotNil(cache.load(key: serverTag + "-nodes-partition=mpp"))
        XCTAssertNil(cache.load(key: serverTag + "-nodes"))

        fetcher.nodesResult = .failure(.unreachable)
        let other = await makeLoader(fetcher, cache: cache).nodes(partition: "smp")
        XCTAssertEqual(other, .vpnNeeded(last: nil, generatedAt: nil))
        let same = await makeLoader(fetcher, cache: cache).nodes(partition: "mpp")
        XCTAssertEqual(same.value, SampleData.nodes.data)
    }

    func testCacheIsKeptPerServer() async {
        let fetcher = StubFetcher()
        let cache = InMemorySnapshotCache()
        fetcher.gpuResult = .success(SampleData.gpu)
        _ = await makeLoader(fetcher, cache: cache).gpu()

        // Another server: the snapshot of the first one is not shown.
        fetcher.gpuResult = .failure(.unreachable)
        fetcher.settings.serverURL = URL(string: "https://other.example.org")
        let elsewhere = await makeLoader(fetcher, cache: cache).gpu()
        XCTAssertEqual(elsewhere, .vpnNeeded(last: nil, generatedAt: nil))

        // Back on the first server, with or without a trailing slash, it is.
        fetcher.settings.serverURL = URL(string: "https://slurm.example.org/")
        let back = await makeLoader(fetcher, cache: cache).gpu()
        XCTAssertEqual(back.value, SampleData.gpu.data)
    }

    func testCacheIsKeptPerUser() async {
        let fetcher = StubFetcher()
        let cache = InMemorySnapshotCache()
        fetcher.queueResult = .success(SampleData.queue)
        _ = await makeLoader(fetcher, cache: cache).queue()
        XCTAssertNotNil(cache.load(key: serverTag + "-queue-user=alice"))

        fetcher.queueResult = .failure(.unreachable)
        // Naming the configured user is the same view …
        let named = await makeLoader(fetcher, cache: cache).queue(user: .named("alice"))
        XCTAssertEqual(named.value, SampleData.queue.data)
        // … another user, everyone, or a changed username in the settings are not.
        let other = await makeLoader(fetcher, cache: cache).queue(user: .named("bob"))
        XCTAssertEqual(other, .vpnNeeded(last: nil, generatedAt: nil))
        let everyone = await makeLoader(fetcher, cache: cache).queue(user: .everyone)
        XCTAssertEqual(everyone, .vpnNeeded(last: nil, generatedAt: nil))
        fetcher.settings.username = "bob"
        let changed = await makeLoader(fetcher, cache: cache).queue()
        XCTAssertEqual(changed, .vpnNeeded(last: nil, generatedAt: nil))
        fetcher.settings.username = nil
        let unset = await makeLoader(fetcher, cache: cache).queue()
        XCTAssertEqual(unset, .vpnNeeded(last: nil, generatedAt: nil))
    }

    func testEveryoneIsCachedUnderItsOwnKey() async {
        let fetcher = StubFetcher()
        let cache = InMemorySnapshotCache()
        fetcher.runnersResult = .success(SampleData.runners)
        _ = await makeLoader(fetcher, cache: cache).runners(user: .everyone)
        XCTAssertNotNil(cache.load(key: serverTag + "-runners-scope=everyone"))
        XCTAssertNil(cache.load(key: serverTag + "-runners-user=alice"))

        fetcher.queueResult = .success(SampleData.queue)
        _ = await makeLoader(fetcher, cache: cache).queue(partition: "mpp", user: .everyone)
        XCTAssertNotNil(cache.load(key: serverTag + "-queue-partition=mpp-scope=everyone"))
    }

    func testMapKeepsTheState() {
        let content: WidgetContent<Int> = .vpnNeeded(last: 3, generatedAt: generatedAt)
        XCTAssertEqual(content.map { String($0) }, .vpnNeeded(last: "3", generatedAt: generatedAt))
        let live: WidgetContent<Int> = .live(2, generatedAt: generatedAt)
        XCTAssertEqual(live.map { $0 * 2 }, .live(4, generatedAt: generatedAt))
    }

    func testCacheKeys() {
        XCTAssertEqual(SnapshotCacheKey.make(family: .gpu), "gpu")
        XCTAssertEqual(SnapshotCacheKey.make(family: .queue, parameters: ["user": "alice", "partition": "mpp", "qos": nil]), "queue-partition=mpp-user=alice")
        XCTAssertEqual(SnapshotCacheKey.make(family: .qos, parameters: ["user": ""]), "qos")

        let server = URL(string: "https://slurm.example.org")!
        let tag = SnapshotCacheKey.serverTag(server)
        XCTAssertEqual(tag.count, 17)
        XCTAssertTrue(tag.hasPrefix("s"))
        XCTAssertEqual(SnapshotCacheKey.make(family: .gpu, server: server), tag + "-gpu")
        XCTAssertEqual(SnapshotCacheKey.serverTag(URL(string: "https://slurm.example.org/")!), tag)
        XCTAssertNotEqual(SnapshotCacheKey.serverTag(URL(string: "https://slurm.example.org/monitor")!), tag)
        XCTAssertNotEqual(SnapshotCacheKey.serverTag(URL(string: "http://slurm.example.org")!), tag)

        let settings = ServerSettings(serverURL: server, username: "alice", defaultPartition: nil)
        XCTAssertEqual(SnapshotCacheKey.make(family: .qos, parameters: SnapshotCacheKey.userParameters(.configured, settings: settings)), "qos-user=alice")
        XCTAssertEqual(SnapshotCacheKey.make(family: .qos, parameters: SnapshotCacheKey.userParameters(.named("bob"), settings: settings)), "qos-user=bob")
        XCTAssertEqual(SnapshotCacheKey.make(family: .qos, parameters: SnapshotCacheKey.userParameters(.everyone, settings: settings)), "qos-scope=everyone")
        XCTAssertEqual(SnapshotCacheKey.make(family: .qos, parameters: SnapshotCacheKey.userParameters(.configured, settings: ServerSettings())), "qos")
    }

    func testFileCacheStoresAndLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SlurmKitTests-" + UUID().uuidString, isDirectory: true)
        let cache = FileSnapshotCache(directory: directory)
        defer { cache.removeAll() }

        XCTAssertNil(cache.load(key: "gpu"))
        let payload = try SlurmJSON.encode(SampleData.gpu)
        cache.store(payload, key: "gpu", fetchedAt: generatedAt)
        let entry = try XCTUnwrap(cache.load(key: "gpu"))
        XCTAssertEqual(entry.fetchedAt, generatedAt)
        XCTAssertEqual(try SlurmJSON.decode(Snapshot<GpuData>.self, from: entry.payload), SampleData.gpu)

        cache.store(payload, key: "queue-user=a/b", fetchedAt: generatedAt)
        XCTAssertEqual(cache.fileURL(key: "queue-user=a/b").lastPathComponent, "queue-user=a_b.json")
        XCTAssertNotNil(cache.load(key: "queue-user=a/b"))

        cache.removeAll()
        XCTAssertNil(cache.load(key: "gpu"))
    }

    func testSettingsRoundTrip() throws {
        let suite = "SlurmKitTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ServerSettings.load(from: defaults), ServerSettings())
        XCTAssertFalse(ServerSettings.load(from: defaults).isConfigured)

        let settings = ServerSettings(serverURL: URL(string: "https://slurm.example.org"), username: "alice", defaultPartition: "mpp")
        settings.save(to: defaults)
        XCTAssertEqual(ServerSettings.load(from: defaults), settings)

        ServerSettings(serverURL: settings.serverURL, username: nil, defaultPartition: " ").save(to: defaults)
        let reloaded = ServerSettings.load(from: defaults)
        XCTAssertNil(reloaded.username)
        XCTAssertNil(reloaded.defaultPartition)
        XCTAssertTrue(reloaded.isConfigured)
    }

    func testParseServerURL() {
        XCTAssertEqual(ServerSettings.parseServerURL(" slurm.example.org/ ")?.absoluteString, "https://slurm.example.org")
        XCTAssertEqual(ServerSettings.parseServerURL("http://slurm.example.org:8080")?.absoluteString, "http://slurm.example.org:8080")
        XCTAssertEqual(ServerSettings.parseServerURL("https://slurm.example.org/monitor/")?.absoluteString, "https://slurm.example.org/monitor")
        XCTAssertNil(ServerSettings.parseServerURL(""))
        XCTAssertNil(ServerSettings.parseServerURL("   "))
    }

    func testInMemoryCredentialStore() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.load())
        try store.save(.staticToken("abc"))
        XCTAssertEqual(try store.load(), .staticToken("abc"))
        XCTAssertEqual(try store.load()?.bearerToken, "abc")
        let tokens = OIDCTokens(accessToken: "access", refreshToken: "refresh", expiresAt: generatedAt)
        try store.save(.oidc(tokens))
        XCTAssertEqual(try store.load()?.bearerToken, "access")
        let encoded = try JSONEncoder().encode(Credentials.oidc(tokens))
        XCTAssertEqual(try JSONDecoder().decode(Credentials.self, from: encoded), .oidc(tokens))
        try store.clear()
        XCTAssertNil(try store.load())
    }
}
