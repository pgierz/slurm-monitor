import Foundation

/// Static, realistic sample values matching the figures of the mockups, for
/// previews, placeholders and screenshot tests. Everything is deterministic.
public enum SampleData {
    /// Name of the sample cluster.
    public static let cluster = "albedo"

    /// 2026-10-01T12:32:07Z, the snapshot time of every sample.
    public static let generatedAt = Date(timeIntervalSince1970: 1_790_857_927)

    /// 2026-10-01T00:00:00Z.
    private static let dayStart = Date(timeIntervalSince1970: 1_790_812_800)

    /// A time on the sample day, in UTC.
    private static func time(_ hour: Int, _ minute: Int) -> Date {
        dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    /// 72 times, one per five minutes, ending at 12:30 UTC, oldest first.
    private static func historyTimes() -> [Date] {
        let last = time(12, 30)
        return (0..<72).map { last.addingTimeInterval(TimeInterval(($0 - 71) * 300)) }
    }

    private static func snapshot<T: Codable & Sendable & Equatable>(_ data: T) -> Snapshot<T> {
        Snapshot(cluster: cluster, generatedAt: generatedAt, stale: false, data: data)
    }

    // MARK: Queue

    /// Queue: 412 running, 96 pending; mine 12 R and 3 PD.
    public static let queue: Snapshot<QueueData> = snapshot(makeQueue())

    private static func makeQueue() -> QueueData {
        let elapsed = [18720, 17100, 15300, 12600, 9000, 8100, 6300, 5400, 3600, 2700, 1200, 300]
        let names = ["awiesm_lig125k", "awiesm_lig126k", "awiesm_pi_ctrl", "fesom_core2", "echam_t63_spinup", "oifs_tco159", "post_lig125k", "cmor_lig125k", "train_emulator", "fesom_mesh_part", "regrid_era5", "plot_amoc"]
        let partitions = ["mpp", "mpp", "mpp", "mpp", "mpp", "mpp", "smp", "smp", "gpu", "smp", "smp", "smp"]
        let resources = ["16 nodes", "16 nodes", "16 nodes", "8 nodes", "4 nodes", "12 nodes", "64 cores", "32 cores", "2 A100", "16 cores", "8 cores", "4 cores"]
        let limits = [43200, 43200, 43200, 43200, 28800, 43200, 14400, 14400, 43200, 7200, 7200, 1800]

        var jobs: [JobSummary] = []
        for index in 0..<elapsed.count {
            jobs.append(JobSummary(jobId: 4_711_001 + index, name: names[index], state: .running, partition: partitions[index], resources: resources[index], elapsedSeconds: elapsed[index], timeLimitSeconds: limits[index], estimatedStart: nil, reason: nil))
        }
        jobs.append(JobSummary(jobId: 4_711_020, name: "awiesm_lig127k", state: .pending, partition: "mpp", resources: "16 nodes", elapsedSeconds: 0, timeLimitSeconds: 43200, estimatedStart: time(13, 40), reason: "Priority"))
        jobs.append(JobSummary(jobId: 4_711_021, name: "awiesm_lig128k", state: .pending, partition: "mpp", resources: "16 nodes", elapsedSeconds: 0, timeLimitSeconds: 43200, estimatedStart: time(15, 5), reason: "Resources"))
        jobs.append(JobSummary(jobId: 4_711_022, name: "post_lig127k", state: .pending, partition: "smp", resources: "64 cores", elapsedSeconds: 0, timeLimitSeconds: 14400, estimatedStart: nil, reason: "Dependency"))

        let times = historyTimes()
        var history: [QueueHistoryPoint] = []
        for index in 0..<times.count {
            history.append(QueueHistoryPoint(t: times[index], running: 380 + (index * 7) % 40, pending: 78 + (index * 5) % 30))
        }
        history[history.count - 1] = QueueHistoryPoint(t: times[times.count - 1], running: 412, pending: 96)

        return QueueData(
            partition: nil,
            qos: nil,
            user: "alice",
            running: 412,
            pending: 96,
            mine: JobCounts(running: 12, pending: 3),
            pendingByReason: [
                ReasonCount(reason: "Priority", count: 58),
                ReasonCount(reason: "Resources", count: 27),
                ReasonCount(reason: "QOS limit", count: 8),
                ReasonCount(reason: "Dependency", count: 3),
            ],
            myJobsTotal: 15,
            myJobs: jobs,
            history: history
        )
    }

    // MARK: Nodes

    /// Nodes: 240 in total; mpp 170, smp 50, fat 12, gpu 8.
    public static let nodes: Snapshot<NodesData> = snapshot(makeNodes())

    private static func makeNodes() -> NodesData {
        let gpuStates: [NodeState] = [.allocated, .allocated, .allocated, .drained, .allocated, .allocated, .idle, .idle]
        let partitions = [
            makePartition(name: "mpp", prefix: "prod", allocated: 148, idle: 14, drained: 6, down: 2, seed: 11),
            makePartition(name: "smp", prefix: "smp", allocated: 40, idle: 6, drained: 3, down: 1, seed: 23),
            makePartition(name: "fat", prefix: "fat", allocated: 5, idle: 4, drained: 1, down: 2, seed: 37),
            makePartition(name: "gpu", prefix: "gpu", states: gpuStates),
        ]
        return NodesData(total: 240, allocated: 198, idle: 26, drained: 11, down: 5, partitions: partitions)
    }

    private static func makePartition(name: String, prefix: String, allocated: Int, idle: Int, drained: Int, down: Int, seed: UInt64) -> PartitionNodes {
        var states: [NodeState] = []
        states.append(contentsOf: Array(repeating: NodeState.allocated, count: allocated))
        states.append(contentsOf: Array(repeating: NodeState.idle, count: idle))
        states.append(contentsOf: Array(repeating: NodeState.drained, count: drained))
        states.append(contentsOf: Array(repeating: NodeState.down, count: down))
        return makePartition(name: name, prefix: prefix, states: deterministicShuffle(states, seed: seed))
    }

    private static func makePartition(name: String, prefix: String, states: [NodeState]) -> PartitionNodes {
        var nodes: [NodeInfo] = []
        for index in 0..<states.count {
            nodes.append(NodeInfo(name: nodeName(prefix, index + 1), state: states[index]))
        }
        return PartitionNodes(
            name: name,
            total: states.count,
            allocated: states.filter { $0 == .allocated }.count,
            idle: states.filter { $0 == .idle }.count,
            drained: states.filter { $0 == .drained }.count,
            down: states.filter { $0 == .down }.count,
            nodes: nodes
        )
    }

    private static func nodeName(_ prefix: String, _ number: Int) -> String {
        let digits = String(number)
        let padding = String(repeating: "0", count: max(0, 3 - digits.count))
        return prefix + "-" + padding + digits
    }

    /// Fisher–Yates with a fixed linear congruential generator.
    private static func deterministicShuffle(_ states: [NodeState], seed: UInt64) -> [NodeState] {
        var result = states
        var value = seed
        var index = result.count - 1
        while index > 0 {
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let other = Int((value >> 33) % UInt64(index + 1))
            result.swapAt(index, other)
            index -= 1
        }
        return result
    }

    // MARK: QOS

    /// QOS: 12h, 48h (above 95 % of its limit) and 30min.
    public static let qos: Snapshot<QosData> = snapshot(
        QosData(
            user: "alice",
            account: "hpc",
            fairshare: 0.42,
            qos: [
                QosEntry(name: "12h", cpusInUse: 14200, cpuLimit: 18000, runningJobs: 310, pendingJobs: 61, maxWallSeconds: 43200),
                QosEntry(name: "48h", cpusInUse: 5800, cpuLimit: 6000, runningJobs: 74, pendingJobs: 29, maxWallSeconds: 172_800),
                QosEntry(name: "30min", cpusInUse: 620, cpuLimit: 2000, runningJobs: 28, pendingJobs: 6, maxWallSeconds: 1800),
            ]
        )
    )

    // MARK: GPU

    /// GPU with metrics: 14 of 24 allocated, A100 11/16, A40 3/8, three idle-allocated cards.
    public static let gpu: Snapshot<GpuData> = snapshot(makeGpu())

    /// The same cluster without card metrics.
    public static let gpuNoMetrics: Snapshot<GpuData> = snapshot(withoutMetrics(makeGpu()))

    private static func busy(_ index: Int, _ utilisation: Double, _ memoryUsed: Int, _ memoryTotal: Int, _ temperature: Double, _ power: Double, _ user: String) -> GpuCard {
        GpuCard(index: index, state: .busy, utilisation: utilisation, memoryUsedMib: memoryUsed, memoryTotalMib: memoryTotal, temperatureC: temperature, powerW: power, user: user)
    }

    private static func idleAllocated(_ index: Int, _ memoryUsed: Int, _ memoryTotal: Int, _ temperature: Double, _ power: Double, _ user: String) -> GpuCard {
        GpuCard(index: index, state: .idleAllocated, utilisation: 0.0, memoryUsedMib: memoryUsed, memoryTotalMib: memoryTotal, temperatureC: temperature, powerW: power, user: user)
    }

    private static func unallocated(_ index: Int, _ state: CardState, _ memoryTotal: Int) -> GpuCard {
        GpuCard(index: index, state: state, utilisation: 0.0, memoryUsedMib: 0, memoryTotalMib: memoryTotal, temperatureC: 31, powerW: 52, user: nil)
    }

    private static func makeGpu() -> GpuData {
        let a100 = 40960
        let a40 = 46068
        let nodes = [
            GpuNode(name: "gpu-001", type: "a100", state: .allocated, cards: [
                busy(0, 0.97, 36864, a100, 74, 286, "alice"),
                busy(1, 0.94, 35120, a100, 72, 279, "alice"),
                busy(2, 0.88, 30208, a100, 70, 262, "alice"),
                busy(3, 0.91, 33792, a100, 71, 270, "alice"),
            ]),
            GpuNode(name: "gpu-002", type: "a100", state: .allocated, cards: [
                busy(0, 0.76, 28160, a100, 66, 231, "bob"),
                busy(1, 0.81, 29440, a100, 68, 244, "bob"),
                busy(2, 0.63, 18432, a100, 61, 198, "bob"),
                idleAllocated(3, 1024, a100, 38, 61, "carol"),
            ]),
            GpuNode(name: "gpu-003", type: "a100", state: .allocated, cards: [
                busy(0, 0.99, 39936, a100, 77, 295, "dave"),
                busy(1, 0.52, 12288, a100, 58, 176, "dave"),
                idleAllocated(2, 512, a100, 36, 58, "carol"),
                unallocated(3, .free, a100),
            ]),
            GpuNode(name: "gpu-004", type: "a100", state: .drained, cards: [
                unallocated(0, .drained, a100),
                unallocated(1, .drained, a100),
                unallocated(2, .drained, a100),
                unallocated(3, .drained, a100),
            ]),
            GpuNode(name: "gpu-005", type: "a40", state: .allocated, cards: [
                busy(0, 0.84, 31744, a40, 69, 248, "erin"),
                idleAllocated(1, 2048, a40, 39, 64, "erin"),
            ]),
            GpuNode(name: "gpu-006", type: "a40", state: .allocated, cards: [
                busy(0, 0.47, 9216, a40, 55, 151, "bob"),
                unallocated(1, .free, a40),
            ]),
            GpuNode(name: "gpu-007", type: "a40", state: .idle, cards: [
                unallocated(0, .free, a40),
                unallocated(1, .free, a40),
            ]),
            GpuNode(name: "gpu-008", type: "a40", state: .idle, cards: [
                unallocated(0, .free, a40),
                unallocated(1, .free, a40),
            ]),
        ]

        let times = historyTimes()
        var history: [GpuHistoryPoint] = []
        for index in 0..<times.count {
            let allocated = 0.42 + Double((index * 3) % 20) / 100
            let utilisation = 0.55 + Double((index * 7) % 30) / 100
            history.append(GpuHistoryPoint(t: times[index], allocatedFraction: allocated, utilisation: utilisation))
        }
        history[history.count - 1] = GpuHistoryPoint(t: times[times.count - 1], allocatedFraction: 0.58, utilisation: 0.71)

        return GpuData(
            metricsAvailable: true,
            total: 24,
            allocated: 14,
            idleAllocated: 3,
            pendingJobs: 6,
            longestWaitSeconds: 11520,
            types: [
                GpuTypeCount(type: "a100", label: "A100", total: 16, allocated: 11),
                GpuTypeCount(type: "a40", label: "A40", total: 8, allocated: 3),
            ],
            nodes: nodes,
            topUsers: [
                GpuUserCards(user: "alice", cards: 4),
                GpuUserCards(user: "bob", cards: 4),
                GpuUserCards(user: "carol", cards: 2),
                GpuUserCards(user: "dave", cards: 2),
                GpuUserCards(user: "erin", cards: 2),
            ],
            history: history
        )
    }

    /// What the server sends for the same cluster when metrics are unavailable.
    private static func withoutMetrics(_ data: GpuData) -> GpuData {
        var result = data
        result.metricsAvailable = false
        result.idleAllocated = nil
        result.nodes = data.nodes.map { node in
            var copy = node
            copy.cards = node.cards.map { card in
                let state: CardState = (card.state == .busy || card.state == .idleAllocated) ? .allocated : card.state
                return GpuCard(index: card.index, state: state, utilisation: nil, memoryUsedMib: nil, memoryTotalMib: nil, temperatureC: nil, powerW: nil, user: card.user)
            }
            return copy
        }
        result.history = data.history.map { GpuHistoryPoint(t: $0.t, allocatedFraction: $0.allocatedFraction, utilisation: nil) }
        return result
    }

    // MARK: Runners

    /// Runners: CI 4 alive, 7 waiting, 18 min; three Dask clusters; JupyterHub 23/4/2.
    public static let runners: Snapshot<RunnersData> = snapshot(
        RunnersData(
            ci: CiRunners(runnersAlive: 4, jobsWaiting: 7, oldestWaitSeconds: 1080),
            dask: DaskRunners(clusters: [
                DaskCluster(id: "a3f1", owner: "alice", schedulerAlive: true, workersRunning: 14, workersRequested: 16, walltimeLeftSeconds: 2520),
                DaskCluster(id: "7c2e", owner: "bob", schedulerAlive: true, workersRunning: 8, workersRequested: 8, walltimeLeftSeconds: 600),
                DaskCluster(id: "d90b", owner: "carol", schedulerAlive: false, workersRunning: 0, workersRequested: 4, walltimeLeftSeconds: nil),
            ]),
            jupyterhub: JupyterHubRunners(sessions: 23, withGpu: 4, nearWalltime: 2),
            extra: [
                ExtraRunnerKind(key: "matlab", label: "MATLAB", running: 3, pending: 0),
            ]
        )
    )

    // MARK: Other endpoints

    /// A healthy server.
    public static let health = HealthStatus(status: "ok", version: "1.0.0", schemaVersion: 1, lastPollAt: generatedAt, lastPollOk: true)

    /// Both methods enabled, with an example issuer.
    public static let authConfig = AuthConfig(
        methods: ["token", "oidc"],
        oidc: OIDCConfig(issuer: "https://login.example.org/oauth2", clientId: "slurm-monitor-app", scopes: ["openid", "profile", "email", "eduperson_entitlement"])
    )

    /// Example settings.
    public static let settings = ServerSettings(serverURL: URL(string: "https://slurm.example.org"), username: "alice", defaultPartition: nil)
}
