import Foundation

// MARK: - Envelope

/// The envelope every family endpoint returns.
public struct Snapshot<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var cluster: String
    /// Time of the slurmrestd poll the snapshot is built from.
    public var generatedAt: Date
    /// True when the most recent poll failed and the server answers from an older one.
    public var stale: Bool
    public var data: T

    public init(schemaVersion: Int = SlurmKitConstants.schemaVersion, cluster: String, generatedAt: Date, stale: Bool = false, data: T) {
        self.schemaVersion = schemaVersion
        self.cluster = cluster
        self.generatedAt = generatedAt
        self.stale = stale
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cluster
        case generatedAt = "generated_at"
        case stale
        case data
    }
}

// MARK: - Enumerations tolerant of unknown values

/// State of a listed job. The server lists running and pending jobs only.
public enum JobState: String, Codable, Sendable, Equatable, CaseIterable {
    case running = "R"
    case pending = "PD"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobState(rawValue: raw) ?? .unknown
    }
}

/// Normalised node state.
public enum NodeState: String, Codable, Sendable, Equatable, CaseIterable {
    case allocated
    case idle
    case drained
    case down
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NodeState(rawValue: raw) ?? .unknown
    }
}

/// State of one GPU card.
public enum CardState: String, Codable, Sendable, Equatable, CaseIterable {
    /// Allocated, utilisation at or above 5 %.
    case busy
    /// Allocated, utilisation below 5 %.
    case idleAllocated = "idle_allocated"
    /// Allocated, no metrics available.
    case allocated
    case free
    case drained
    case down
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CardState(rawValue: raw) ?? .unknown
    }

    /// True for `busy`, `idleAllocated` and `allocated`.
    public var isAllocated: Bool {
        self == .busy || self == .idleAllocated || self == .allocated
    }
}

// MARK: - Queue

/// Running and pending job counts.
public struct JobCounts: Codable, Sendable, Equatable {
    public var running: Int
    public var pending: Int

    public init(running: Int, pending: Int) {
        self.running = running
        self.pending = pending
    }
}

/// Number of pending jobs for one normalised reason.
public struct ReasonCount: Codable, Sendable, Equatable, Identifiable {
    public var reason: String
    public var count: Int

    public var id: String { reason }

    public init(reason: String, count: Int) {
        self.reason = reason
        self.count = count
    }
}

/// One of the user's jobs.
public struct JobSummary: Codable, Sendable, Equatable, Identifiable {
    public var jobId: Int
    public var name: String
    public var state: JobState
    public var partition: String
    /// Short human string such as `16 nodes`, `64 cores` or `2 A100`.
    public var resources: String
    public var elapsedSeconds: Int
    /// `nil` for unlimited.
    public var timeLimitSeconds: Int?
    public var estimatedStart: Date?
    public var reason: String?

    public var id: Int { jobId }

    public init(jobId: Int, name: String, state: JobState, partition: String, resources: String, elapsedSeconds: Int, timeLimitSeconds: Int?, estimatedStart: Date?, reason: String?) {
        self.jobId = jobId
        self.name = name
        self.state = state
        self.partition = partition
        self.resources = resources
        self.elapsedSeconds = elapsedSeconds
        self.timeLimitSeconds = timeLimitSeconds
        self.estimatedStart = estimatedStart
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case name
        case state
        case partition
        case resources
        case elapsedSeconds = "elapsed_seconds"
        case timeLimitSeconds = "time_limit_seconds"
        case estimatedStart = "estimated_start"
        case reason
    }
}

/// One point of the queue history.
public struct QueueHistoryPoint: Codable, Sendable, Equatable {
    public var t: Date
    public var running: Int
    public var pending: Int

    public init(t: Date, running: Int, pending: Int) {
        self.t = t
        self.running = running
        self.pending = pending
    }
}

/// `data` of `GET /api/v1/queue`.
public struct QueueData: Codable, Sendable, Equatable {
    public var partition: String?
    public var qos: String?
    public var user: String?
    public var running: Int
    public var pending: Int
    /// `nil` when no user is known.
    public var mine: JobCounts?
    public var pendingByReason: [ReasonCount]
    public var myJobsTotal: Int
    public var myJobs: [JobSummary]
    public var history: [QueueHistoryPoint]

    public init(partition: String?, qos: String?, user: String?, running: Int, pending: Int, mine: JobCounts?, pendingByReason: [ReasonCount], myJobsTotal: Int, myJobs: [JobSummary], history: [QueueHistoryPoint]) {
        self.partition = partition
        self.qos = qos
        self.user = user
        self.running = running
        self.pending = pending
        self.mine = mine
        self.pendingByReason = pendingByReason
        self.myJobsTotal = myJobsTotal
        self.myJobs = myJobs
        self.history = history
    }

    enum CodingKeys: String, CodingKey {
        case partition
        case qos
        case user
        case running
        case pending
        case mine
        case pendingByReason = "pending_by_reason"
        case myJobsTotal = "my_jobs_total"
        case myJobs = "my_jobs"
        case history
    }
}

// MARK: - Nodes

/// One node with its normalised state.
public struct NodeInfo: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var state: NodeState

    public var id: String { name }

    public init(name: String, state: NodeState) {
        self.name = name
        self.state = state
    }
}

/// Node counts and node list of one partition.
public struct PartitionNodes: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var total: Int
    public var allocated: Int
    public var idle: Int
    public var drained: Int
    public var down: Int
    public var nodes: [NodeInfo]

    public var id: String { name }

    public init(name: String, total: Int, allocated: Int, idle: Int, drained: Int, down: Int, nodes: [NodeInfo]) {
        self.name = name
        self.total = total
        self.allocated = allocated
        self.idle = idle
        self.drained = drained
        self.down = down
        self.nodes = nodes
    }
}

/// `data` of `GET /api/v1/nodes`.
public struct NodesData: Codable, Sendable, Equatable {
    public var total: Int
    public var allocated: Int
    public var idle: Int
    public var drained: Int
    public var down: Int
    public var partitions: [PartitionNodes]

    public init(total: Int, allocated: Int, idle: Int, drained: Int, down: Int, partitions: [PartitionNodes]) {
        self.total = total
        self.allocated = allocated
        self.idle = idle
        self.drained = drained
        self.down = down
        self.partitions = partitions
    }
}

// MARK: - QOS

/// CPU use and limits of one QOS.
public struct QosEntry: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var cpusInUse: Int
    /// QOS group CPU limit, `nil` when unset.
    public var cpuLimit: Int?
    public var runningJobs: Int
    public var pendingJobs: Int
    public var maxWallSeconds: Int?

    public var id: String { name }

    public init(name: String, cpusInUse: Int, cpuLimit: Int?, runningJobs: Int, pendingJobs: Int, maxWallSeconds: Int?) {
        self.name = name
        self.cpusInUse = cpusInUse
        self.cpuLimit = cpuLimit
        self.runningJobs = runningJobs
        self.pendingJobs = pendingJobs
        self.maxWallSeconds = maxWallSeconds
    }

    enum CodingKeys: String, CodingKey {
        case name
        case cpusInUse = "cpus_in_use"
        case cpuLimit = "cpu_limit"
        case runningJobs = "running_jobs"
        case pendingJobs = "pending_jobs"
        case maxWallSeconds = "max_wall_seconds"
    }
}

/// `data` of `GET /api/v1/qos`.
public struct QosData: Codable, Sendable, Equatable {
    public var user: String?
    public var account: String?
    /// Normalised fairshare factor, 0…1.
    public var fairshare: Double?
    public var qos: [QosEntry]

    public init(user: String?, account: String?, fairshare: Double?, qos: [QosEntry]) {
        self.user = user
        self.account = account
        self.fairshare = fairshare
        self.qos = qos
    }
}

// MARK: - GPU

/// Card counts of one GPU type.
public struct GpuTypeCount: Codable, Sendable, Equatable, Identifiable {
    /// Lower-case GRES type, for example `a100`.
    public var type: String
    /// Display name, for example `A100`.
    public var label: String
    public var total: Int
    public var allocated: Int

    public var id: String { type }

    public init(type: String, label: String, total: Int, allocated: Int) {
        self.type = type
        self.label = label
        self.total = total
        self.allocated = allocated
    }
}

/// One GPU card. All metric fields are `nil` when metrics are unavailable.
public struct GpuCard: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var state: CardState
    /// Utilisation, 0…1.
    public var utilisation: Double?
    public var memoryUsedMib: Int?
    public var memoryTotalMib: Int?
    public var temperatureC: Double?
    public var powerW: Double?
    public var user: String?

    public var id: Int { index }

    public init(index: Int, state: CardState, utilisation: Double?, memoryUsedMib: Int?, memoryTotalMib: Int?, temperatureC: Double?, powerW: Double?, user: String?) {
        self.index = index
        self.state = state
        self.utilisation = utilisation
        self.memoryUsedMib = memoryUsedMib
        self.memoryTotalMib = memoryTotalMib
        self.temperatureC = temperatureC
        self.powerW = powerW
        self.user = user
    }

    enum CodingKeys: String, CodingKey {
        case index
        case state
        case utilisation
        case memoryUsedMib = "memory_used_mib"
        case memoryTotalMib = "memory_total_mib"
        case temperatureC = "temperature_c"
        case powerW = "power_w"
        case user
    }
}

/// One GPU node with its cards.
public struct GpuNode: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var type: String
    public var state: NodeState
    public var cards: [GpuCard]

    public var id: String { name }

    public init(name: String, type: String, state: NodeState, cards: [GpuCard]) {
        self.name = name
        self.type = type
        self.state = state
        self.cards = cards
    }
}

/// Number of cards one user holds.
public struct GpuUserCards: Codable, Sendable, Equatable, Identifiable {
    public var user: String
    public var cards: Int

    public var id: String { user }

    public init(user: String, cards: Int) {
        self.user = user
        self.cards = cards
    }
}

/// One point of the GPU history.
public struct GpuHistoryPoint: Codable, Sendable, Equatable {
    public var t: Date
    /// Allocated cards over all cards, 0…1.
    public var allocatedFraction: Double
    /// Mean utilisation over allocated cards, `nil` without metrics.
    public var utilisation: Double?

    public init(t: Date, allocatedFraction: Double, utilisation: Double?) {
        self.t = t
        self.allocatedFraction = allocatedFraction
        self.utilisation = utilisation
    }

    enum CodingKeys: String, CodingKey {
        case t
        case allocatedFraction = "allocated_fraction"
        case utilisation
    }
}

/// `data` of `GET /api/v1/gpu`.
public struct GpuData: Codable, Sendable, Equatable {
    public var metricsAvailable: Bool
    public var total: Int
    public var allocated: Int
    /// `nil` when metrics are unavailable.
    public var idleAllocated: Int?
    public var pendingJobs: Int
    public var longestWaitSeconds: Int?
    public var types: [GpuTypeCount]
    public var nodes: [GpuNode]
    public var topUsers: [GpuUserCards]
    public var history: [GpuHistoryPoint]

    public init(metricsAvailable: Bool, total: Int, allocated: Int, idleAllocated: Int?, pendingJobs: Int, longestWaitSeconds: Int?, types: [GpuTypeCount], nodes: [GpuNode], topUsers: [GpuUserCards], history: [GpuHistoryPoint]) {
        self.metricsAvailable = metricsAvailable
        self.total = total
        self.allocated = allocated
        self.idleAllocated = idleAllocated
        self.pendingJobs = pendingJobs
        self.longestWaitSeconds = longestWaitSeconds
        self.types = types
        self.nodes = nodes
        self.topUsers = topUsers
        self.history = history
    }

    enum CodingKeys: String, CodingKey {
        case metricsAvailable = "metrics_available"
        case total
        case allocated
        case idleAllocated = "idle_allocated"
        case pendingJobs = "pending_jobs"
        case longestWaitSeconds = "longest_wait_seconds"
        case types
        case nodes
        case topUsers = "top_users"
        case history
    }
}

// MARK: - Runners

/// CI runner figures.
public struct CiRunners: Codable, Sendable, Equatable {
    public var runnersAlive: Int
    public var jobsWaiting: Int
    /// `nil` when no job waits.
    public var oldestWaitSeconds: Int?

    public init(runnersAlive: Int, jobsWaiting: Int, oldestWaitSeconds: Int?) {
        self.runnersAlive = runnersAlive
        self.jobsWaiting = jobsWaiting
        self.oldestWaitSeconds = oldestWaitSeconds
    }

    enum CodingKeys: String, CodingKey {
        case runnersAlive = "runners_alive"
        case jobsWaiting = "jobs_waiting"
        case oldestWaitSeconds = "oldest_wait_seconds"
    }
}

/// One Dask cluster.
public struct DaskCluster: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var owner: String
    public var schedulerAlive: Bool
    public var workersRunning: Int
    public var workersRequested: Int
    /// Minimum over the running workers, `nil` when none run.
    public var walltimeLeftSeconds: Int?

    public init(id: String, owner: String, schedulerAlive: Bool, workersRunning: Int, workersRequested: Int, walltimeLeftSeconds: Int?) {
        self.id = id
        self.owner = owner
        self.schedulerAlive = schedulerAlive
        self.workersRunning = workersRunning
        self.workersRequested = workersRequested
        self.walltimeLeftSeconds = walltimeLeftSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id
        case owner
        case schedulerAlive = "scheduler_alive"
        case workersRunning = "workers_running"
        case workersRequested = "workers_requested"
        case walltimeLeftSeconds = "walltime_left_seconds"
    }
}

/// The list of Dask clusters.
public struct DaskRunners: Codable, Sendable, Equatable {
    public var clusters: [DaskCluster]

    public init(clusters: [DaskCluster]) {
        self.clusters = clusters
    }
}

/// JupyterHub session figures.
public struct JupyterHubRunners: Codable, Sendable, Equatable {
    public var sessions: Int
    public var withGpu: Int
    /// Sessions with less than 15 minutes left.
    public var nearWalltime: Int

    public init(sessions: Int, withGpu: Int, nearWalltime: Int) {
        self.sessions = sessions
        self.withGpu = withGpu
        self.nearWalltime = nearWalltime
    }

    enum CodingKeys: String, CodingKey {
        case sessions
        case withGpu = "with_gpu"
        case nearWalltime = "near_walltime"
    }
}

/// A further job kind set in the server configuration.
public struct ExtraRunnerKind: Codable, Sendable, Equatable, Identifiable {
    public var key: String
    public var label: String
    public var running: Int
    public var pending: Int

    public var id: String { key }

    public init(key: String, label: String, running: Int, pending: Int) {
        self.key = key
        self.label = label
        self.running = running
        self.pending = pending
    }
}

/// `data` of `GET /api/v1/runners`.
public struct RunnersData: Codable, Sendable, Equatable {
    public var ci: CiRunners
    public var dask: DaskRunners
    public var jupyterhub: JupyterHubRunners
    public var extra: [ExtraRunnerKind]

    public init(ci: CiRunners, dask: DaskRunners, jupyterhub: JupyterHubRunners, extra: [ExtraRunnerKind]) {
        self.ci = ci
        self.dask = dask
        self.jupyterhub = jupyterhub
        self.extra = extra
    }
}

// MARK: - Endpoints without envelope

/// Response of `GET /api/v1/health`.
public struct HealthStatus: Codable, Sendable, Equatable {
    public var status: String
    public var version: String
    public var schemaVersion: Int
    public var lastPollAt: Date?
    public var lastPollOk: Bool?

    public init(status: String, version: String, schemaVersion: Int, lastPollAt: Date?, lastPollOk: Bool?) {
        self.status = status
        self.version = version
        self.schemaVersion = schemaVersion
        self.lastPollAt = lastPollAt
        self.lastPollOk = lastPollOk
    }

    enum CodingKeys: String, CodingKey {
        case status
        case version
        case schemaVersion = "schema_version"
        case lastPollAt = "last_poll_at"
        case lastPollOk = "last_poll_ok"
    }
}

/// OIDC settings published by the server.
public struct OIDCConfig: Codable, Sendable, Equatable {
    public var issuer: String
    public var clientId: String
    public var scopes: [String]

    public init(issuer: String, clientId: String, scopes: [String]) {
        self.issuer = issuer
        self.clientId = clientId
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey {
        case issuer
        case clientId = "client_id"
        case scopes
    }
}

/// Response of `GET /api/v1/auth/config`.
public struct AuthConfig: Codable, Sendable, Equatable {
    /// Enabled methods, `token` and/or `oidc`.
    public var methods: [String]
    /// `nil` when OIDC is not enabled.
    public var oidc: OIDCConfig?

    public init(methods: [String], oidc: OIDCConfig?) {
        self.methods = methods
        self.oidc = oidc
    }

    /// True when the static token method is enabled.
    public var supportsToken: Bool { methods.contains("token") }
    /// True when OIDC is enabled and configured.
    public var supportsOIDC: Bool { methods.contains("oidc") && oidc != nil }
}

/// Response of `GET /api/v1/me`.
public struct Identity: Codable, Sendable, Equatable {
    /// `token` or `oidc`.
    public var method: String
    public var subject: String?
    /// The Slurm username, `nil` when it cannot be derived.
    public var username: String?

    public init(method: String, subject: String?, username: String?) {
        self.method = method
        self.subject = subject
        self.username = username
    }
}
