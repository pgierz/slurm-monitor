import Foundation
import XCTest
@testable import SlurmKit

final class DecodingTests: XCTestCase {
    private let generatedAt = Date(timeIntervalSince1970: 1_790_857_927)

    func testQueueExample() throws {
        let snapshot = try SlurmJSON.decode(Snapshot<QueueData>.self, from: TestJSON.envelope(TestJSON.queue))
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.cluster, "albedo")
        XCTAssertEqual(snapshot.generatedAt, generatedAt)
        XCTAssertFalse(snapshot.stale)
        let data = snapshot.data
        XCTAssertNil(data.partition)
        XCTAssertNil(data.qos)
        XCTAssertEqual(data.user, "pgierz")
        XCTAssertEqual(data.running, 412)
        XCTAssertEqual(data.pending, 96)
        XCTAssertEqual(data.mine, JobCounts(running: 12, pending: 3))
        XCTAssertEqual(data.pendingByReason.count, 4)
        XCTAssertEqual(data.pendingByReason[2], ReasonCount(reason: "QOS limit", count: 8))
        XCTAssertEqual(data.myJobsTotal, 15)
        XCTAssertEqual(data.myJobs.count, 2)
        XCTAssertEqual(data.myJobs[0].jobId, 4_711_001)
        XCTAssertEqual(data.myJobs[0].state, .running)
        XCTAssertEqual(data.myJobs[0].elapsedSeconds, 18720)
        XCTAssertEqual(data.myJobs[0].timeLimitSeconds, 43200)
        XCTAssertNil(data.myJobs[0].estimatedStart)
        XCTAssertNil(data.myJobs[0].reason)
        XCTAssertEqual(data.myJobs[1].state, .pending)
        XCTAssertEqual(data.myJobs[1].estimatedStart, Date(timeIntervalSince1970: 1_790_812_800 + 13 * 3600 + 40 * 60))
        XCTAssertEqual(data.myJobs[1].reason, "Priority")
        XCTAssertEqual(data.history.count, 1)
        XCTAssertEqual(data.history[0].running, 405)
    }

    func testQueueWithoutUser() throws {
        let json = """
        {"partition": "mpp", "qos": null, "user": null, "running": 1, "pending": 0,
         "mine": null, "pending_by_reason": [], "my_jobs_total": 0, "my_jobs": [], "history": []}
        """
        let snapshot = try SlurmJSON.decode(Snapshot<QueueData>.self, from: TestJSON.envelope(json, stale: true))
        XCTAssertTrue(snapshot.stale)
        XCTAssertNil(snapshot.data.mine)
        XCTAssertEqual(snapshot.data.partition, "mpp")
        XCTAssertEqual(snapshot.data.mineLine, "—")
    }

    func testNodesExample() throws {
        let data = try SlurmJSON.decode(Snapshot<NodesData>.self, from: TestJSON.envelope(TestJSON.nodes)).data
        XCTAssertEqual(data.total, 240)
        XCTAssertEqual(data.allocated, 198)
        XCTAssertEqual(data.idle, 26)
        XCTAssertEqual(data.drained, 11)
        XCTAssertEqual(data.down, 5)
        XCTAssertEqual(data.partitions.count, 1)
        XCTAssertEqual(data.partitions[0].name, "mpp")
        XCTAssertEqual(data.partitions[0].total, 170)
        XCTAssertEqual(data.partitions[0].nodes, [NodeInfo(name: "prod-001", state: .allocated)])
    }

    func testQosExample() throws {
        let data = try SlurmJSON.decode(Snapshot<QosData>.self, from: TestJSON.envelope(TestJSON.qos)).data
        XCTAssertEqual(data.user, "pgierz")
        XCTAssertEqual(data.account, "hpc")
        XCTAssertEqual(data.fairshare, 0.42)
        XCTAssertEqual(data.qos, [QosEntry(name: "12h", cpusInUse: 14200, cpuLimit: 18000, runningJobs: 310, pendingJobs: 61, maxWallSeconds: 43200)])
    }

    func testGpuExample() throws {
        let data = try SlurmJSON.decode(Snapshot<GpuData>.self, from: TestJSON.envelope(TestJSON.gpu)).data
        XCTAssertTrue(data.metricsAvailable)
        XCTAssertEqual(data.total, 24)
        XCTAssertEqual(data.allocated, 14)
        XCTAssertEqual(data.idleAllocated, 3)
        XCTAssertEqual(data.pendingJobs, 6)
        XCTAssertEqual(data.longestWaitSeconds, 11520)
        XCTAssertEqual(data.types.count, 2)
        XCTAssertEqual(data.types[0], GpuTypeCount(type: "a100", label: "A100", total: 16, allocated: 11))
        XCTAssertEqual(data.nodes.count, 1)
        XCTAssertEqual(data.nodes[0].state, .allocated)
        let card = data.nodes[0].cards[0]
        XCTAssertEqual(card, GpuCard(index: 0, state: .busy, utilisation: 0.97, memoryUsedMib: 36864, memoryTotalMib: 40960, temperatureC: 74, powerW: 286, user: "pgierz"))
        XCTAssertEqual(data.topUsers, [GpuUserCards(user: "pgierz", cards: 4)])
        XCTAssertEqual(data.history[0].allocatedFraction, 0.58)
        XCTAssertEqual(data.history[0].utilisation, 0.71)
    }

    func testGpuWithoutMetrics() throws {
        let data = try SlurmJSON.decode(Snapshot<GpuData>.self, from: TestJSON.envelope(TestJSON.gpuNoMetrics)).data
        XCTAssertFalse(data.metricsAvailable)
        XCTAssertNil(data.idleAllocated)
        XCTAssertEqual(data.longestWaitSeconds, 0)
        XCTAssertEqual(data.pendingLine, "no jobs pending")
        XCTAssertEqual(data.nodes[0].cards[0].state, .allocated)
        XCTAssertNil(data.nodes[0].cards[0].utilisation)
        XCTAssertNil(data.nodes[0].cards[0].memoryUsedMib)
        XCTAssertNil(data.nodes[0].cards[1].user)
        XCTAssertNil(data.history[0].utilisation)
        XCTAssertFalse(data.showsIdleAllocated)
        XCTAssertEqual(data.sparklineLabel, "allocated, 6 h")
        XCTAssertEqual(data.sparklineValues, [0.58])
    }

    func testRunnersExample() throws {
        let data = try SlurmJSON.decode(Snapshot<RunnersData>.self, from: TestJSON.envelope(TestJSON.runners)).data
        XCTAssertEqual(data.ci, CiRunners(runnersAlive: 4, jobsWaiting: 7, oldestWaitSeconds: 1080))
        XCTAssertEqual(data.dask.clusters, [DaskCluster(id: "a3f1", owner: "pgierz", schedulerAlive: true, workersRunning: 14, workersRequested: 16, walltimeLeftSeconds: 2520)])
        XCTAssertEqual(data.jupyterhub, JupyterHubRunners(sessions: 23, withGpu: 4, nearWalltime: 2))
        XCTAssertEqual(data.extra, [ExtraRunnerKind(key: "matlab", label: "MATLAB", running: 3, pending: 0)])
    }

    func testHealthAuthConfigAndMe() throws {
        let health = try SlurmJSON.decode(HealthStatus.self, from: Data(TestJSON.health.utf8))
        XCTAssertEqual(health, HealthStatus(status: "ok", version: "1.0.0", schemaVersion: 1, lastPollAt: generatedAt, lastPollOk: true))

        let config = try SlurmJSON.decode(AuthConfig.self, from: Data(TestJSON.authConfig.utf8))
        XCTAssertEqual(config.methods, ["token", "oidc"])
        XCTAssertEqual(config.oidc?.issuer, "https://login.example.org/oauth2")
        XCTAssertEqual(config.oidc?.clientId, "slurm-monitor-app")
        XCTAssertEqual(config.oidc?.scopes.count, 4)
        XCTAssertTrue(config.supportsOIDC)
        XCTAssertTrue(config.supportsToken)

        let tokenOnly = try SlurmJSON.decode(AuthConfig.self, from: Data(TestJSON.authConfigNoOIDC.utf8))
        XCTAssertNil(tokenOnly.oidc)
        XCTAssertFalse(tokenOnly.supportsOIDC)

        let me = try SlurmJSON.decode(Identity.self, from: Data(TestJSON.me.utf8))
        XCTAssertEqual(me, Identity(method: "oidc", subject: "abc-123", username: "pgierz"))

        let staticMe = try SlurmJSON.decode(Identity.self, from: Data("{\"method\": \"token\", \"subject\": \"static\", \"username\": null}".utf8))
        XCTAssertNil(staticMe.username)
    }

    func testUnknownEnumValuesDecode() throws {
        XCTAssertEqual(try SlurmJSON.decode([JobState].self, from: Data("[\"R\", \"PD\", \"CG\"]".utf8)), [.running, .pending, .unknown])
        XCTAssertEqual(try SlurmJSON.decode([NodeState].self, from: Data("[\"allocated\", \"idle\", \"drained\", \"down\", \"rebooting\"]".utf8)), [.allocated, .idle, .drained, .down, .unknown])
        XCTAssertEqual(try SlurmJSON.decode([CardState].self, from: Data("[\"busy\", \"idle_allocated\", \"allocated\", \"free\", \"drained\", \"down\", \"melting\"]".utf8)), [.busy, .idleAllocated, .allocated, .free, .drained, .down, .unknown])

        let json = """
        {"total": 1, "allocated": 0, "idle": 0, "drained": 0, "down": 0,
         "partitions": [{"name": "mpp", "total": 1, "allocated": 0, "idle": 0, "drained": 0, "down": 0,
                         "nodes": [{"name": "prod-001", "state": "powering_up", "extra": 1}]}]}
        """
        let data = try SlurmJSON.decode(Snapshot<NodesData>.self, from: TestJSON.envelope(json)).data
        XCTAssertEqual(data.partitions[0].nodes[0].state, .unknown)
    }

    func testSamplesSurviveEncodingAndDecoding() throws {
        XCTAssertEqual(try roundTrip(SampleData.queue), SampleData.queue)
        XCTAssertEqual(try roundTrip(SampleData.nodes), SampleData.nodes)
        XCTAssertEqual(try roundTrip(SampleData.qos), SampleData.qos)
        XCTAssertEqual(try roundTrip(SampleData.gpu), SampleData.gpu)
        XCTAssertEqual(try roundTrip(SampleData.gpuNoMetrics), SampleData.gpuNoMetrics)
        XCTAssertEqual(try roundTrip(SampleData.runners), SampleData.runners)
    }

    func testEncodedFieldNamesAreSnakeCase() throws {
        let text = String(decoding: try SlurmJSON.encode(SampleData.gpu), as: UTF8.self)
        XCTAssertTrue(text.contains("\"schema_version\""))
        XCTAssertTrue(text.contains("\"generated_at\":\"2026-10-01T12:32:07Z\""))
        XCTAssertTrue(text.contains("\"memory_used_mib\""))
        XCTAssertTrue(text.contains("\"idle_allocated\""))
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try SlurmJSON.decode(T.self, from: SlurmJSON.encode(value))
    }

    // MARK: Server-generated samples

    func testServerSampleQueue() throws {
        _ = try SlurmJSON.decode(Snapshot<QueueData>.self, from: try serverSample("queue"))
    }

    func testServerSampleNodes() throws {
        _ = try SlurmJSON.decode(Snapshot<NodesData>.self, from: try serverSample("nodes"))
    }

    func testServerSampleQos() throws {
        _ = try SlurmJSON.decode(Snapshot<QosData>.self, from: try serverSample("qos"))
    }

    func testServerSampleGpu() throws {
        let snapshot = try SlurmJSON.decode(Snapshot<GpuData>.self, from: try serverSample("gpu"))
        XCTAssertFalse(snapshot.data.nodes.flatMap { $0.cards }.contains { $0.state == .unknown })
    }

    func testServerSampleGpuNoMetrics() throws {
        let snapshot = try SlurmJSON.decode(Snapshot<GpuData>.self, from: try serverSample("gpu_no_metrics"))
        XCTAssertFalse(snapshot.data.metricsAvailable)
        XCTAssertNil(snapshot.data.idleAllocated)
    }

    func testServerSampleRunners() throws {
        _ = try SlurmJSON.decode(Snapshot<RunnersData>.self, from: try serverSample("runners"))
    }

    /// Reads `server/tests/data/contract_samples/<name>.json` from the
    /// repository this file lives in; skips the test when it is absent.
    private func serverSample(_ name: String, file: String = #filePath) throws -> Data {
        // …/ios/SlurmKit/Tests/SlurmKitTests/DecodingTests.swift → repository root
        var root = URL(fileURLWithPath: file)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        let url = root
            .appendingPathComponent("server")
            .appendingPathComponent("tests")
            .appendingPathComponent("data")
            .appendingPathComponent("contract_samples")
            .appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("No server sample at \(url.path)")
        }
        return try Data(contentsOf: url)
    }
}
