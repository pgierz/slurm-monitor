import Foundation
import XCTest
@testable import SlurmKit

/// A transport that answers from a closure and records every request.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> (Int, Data)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let (status, data) = try handler(request)
        let url = request.url ?? URL(string: "https://slurm.example.org")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}

/// A fetcher whose five results are set by the test.
final class StubFetcher: SlurmFetching, @unchecked Sendable {
    var settings = ServerSettings(serverURL: URL(string: "https://slurm.example.org"), username: "alice", defaultPartition: nil)
    var queueResult: Result<Snapshot<QueueData>, FetchError> = .failure(.unreachable)
    var nodesResult: Result<Snapshot<NodesData>, FetchError> = .failure(.unreachable)
    var qosResult: Result<Snapshot<QosData>, FetchError> = .failure(.unreachable)
    var gpuResult: Result<Snapshot<GpuData>, FetchError> = .failure(.unreachable)
    var runnersResult: Result<Snapshot<RunnersData>, FetchError> = .failure(.unreachable)

    func queue(partition: String?, user: UserScope, qos: String?) async throws -> Snapshot<QueueData> {
        try queueResult.get()
    }

    func nodes(partition: String?) async throws -> Snapshot<NodesData> {
        try nodesResult.get()
    }

    func qos(user: UserScope) async throws -> Snapshot<QosData> {
        try qosResult.get()
    }

    func gpu() async throws -> Snapshot<GpuData> {
        try gpuResult.get()
    }

    func runners(user: UserScope) async throws -> Snapshot<RunnersData> {
        try runnersResult.get()
    }
}

enum TestJSON {
    /// Wraps a `data` object in the envelope of the contract.
    static func envelope(_ data: String, stale: Bool = false) -> Data {
        let text = """
        {
          "schema_version": 1,
          "cluster": "albedo",
          "generated_at": "2026-10-01T12:32:07Z",
          "stale": \(stale ? "true" : "false"),
          "some_future_field": {"ignored": true},
          "data": \(data)
        }
        """
        return Data(text.utf8)
    }

    static let queue = """
    {
      "partition": null,
      "qos": null,
      "user": "pgierz",
      "running": 412,
      "pending": 96,
      "mine": {"running": 12, "pending": 3},
      "pending_by_reason": [
        {"reason": "Priority", "count": 58},
        {"reason": "Resources", "count": 27},
        {"reason": "QOS limit", "count": 8},
        {"reason": "Dependency", "count": 3}
      ],
      "my_jobs_total": 15,
      "my_jobs": [
        {"job_id": 4711001, "name": "awiesm_lig125k", "state": "R",
         "partition": "mpp", "resources": "16 nodes",
         "elapsed_seconds": 18720, "time_limit_seconds": 43200,
         "estimated_start": null, "reason": null},
        {"job_id": 4711007, "name": "awiesm_lig127k", "state": "PD",
         "partition": "mpp", "resources": "16 nodes",
         "elapsed_seconds": 0, "time_limit_seconds": 43200,
         "estimated_start": "2026-10-01T13:40:00Z", "reason": "Priority"}
      ],
      "history": [
        {"t": "2026-10-01T12:00:00Z", "running": 405, "pending": 91}
      ]
    }
    """

    static let nodes = """
    {
      "total": 240, "allocated": 198, "idle": 26, "drained": 11, "down": 5,
      "partitions": [
        {"name": "mpp", "total": 170, "allocated": 148, "idle": 14,
         "drained": 6, "down": 2,
         "nodes": [{"name": "prod-001", "state": "allocated"}]}
      ]
    }
    """

    static let qos = """
    {
      "user": "pgierz",
      "account": "hpc",
      "fairshare": 0.42,
      "qos": [
        {"name": "12h", "cpus_in_use": 14200, "cpu_limit": 18000,
         "running_jobs": 310, "pending_jobs": 61, "max_wall_seconds": 43200}
      ]
    }
    """

    static let gpu = """
    {
      "metrics_available": true,
      "total": 24, "allocated": 14, "idle_allocated": 3,
      "pending_jobs": 6, "longest_wait_seconds": 11520,
      "types": [
        {"type": "a100", "label": "A100", "total": 16, "allocated": 11},
        {"type": "a40", "label": "A40", "total": 8, "allocated": 3}
      ],
      "nodes": [
        {"name": "gpu-005", "type": "a100", "state": "allocated",
         "cards": [
           {"index": 0, "state": "busy", "utilisation": 0.97,
            "memory_used_mib": 36864, "memory_total_mib": 40960,
            "temperature_c": 74, "power_w": 286, "user": "pgierz"}
         ]}
      ],
      "top_users": [{"user": "pgierz", "cards": 4}],
      "history": [
        {"t": "2026-10-01T12:00:00Z", "allocated_fraction": 0.58,
         "utilisation": 0.71}
      ]
    }
    """

    static let gpuNoMetrics = """
    {
      "metrics_available": false,
      "total": 24, "allocated": 14, "idle_allocated": null,
      "pending_jobs": 0, "longest_wait_seconds": 0,
      "types": [
        {"type": "a100", "label": "A100", "total": 16, "allocated": 11}
      ],
      "nodes": [
        {"name": "gpu-005", "type": "a100", "state": "allocated",
         "cards": [
           {"index": 0, "state": "allocated", "utilisation": null,
            "memory_used_mib": null, "memory_total_mib": null,
            "temperature_c": null, "power_w": null, "user": "pgierz"},
           {"index": 1, "state": "free", "utilisation": null,
            "memory_used_mib": null, "memory_total_mib": null,
            "temperature_c": null, "power_w": null, "user": null}
         ]}
      ],
      "top_users": [],
      "history": [
        {"t": "2026-10-01T12:00:00Z", "allocated_fraction": 0.58,
         "utilisation": null}
      ]
    }
    """

    static let runners = """
    {
      "ci": {"runners_alive": 4, "jobs_waiting": 7, "oldest_wait_seconds": 1080},
      "dask": {"clusters": [
        {"id": "a3f1", "owner": "pgierz", "scheduler_alive": true,
         "workers_running": 14, "workers_requested": 16,
         "walltime_left_seconds": 2520}
      ]},
      "jupyterhub": {"sessions": 23, "with_gpu": 4, "near_walltime": 2},
      "extra": [
        {"key": "matlab", "label": "MATLAB", "running": 3, "pending": 0}
      ]
    }
    """

    static let health = """
    {"status": "ok", "version": "1.0.0", "schema_version": 1,
     "last_poll_at": "2026-10-01T12:32:07Z", "last_poll_ok": true}
    """

    static let authConfig = """
    {"methods": ["token", "oidc"],
     "oidc": {"issuer": "https://login.example.org/oauth2",
              "client_id": "slurm-monitor-app",
              "scopes": ["openid", "profile", "email", "eduperson_entitlement"]}}
    """

    static let authConfigNoOIDC = """
    {"methods": ["token"], "oidc": null}
    """

    static let me = """
    {"method": "oidc", "subject": "abc-123", "username": "pgierz"}
    """
}
