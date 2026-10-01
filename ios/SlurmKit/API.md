# SlurmKit API

Everything public in the package, copied from the sources. Import with
`import SlurmKit`. Foundation only (plus `Security` and `CryptoKit`
internally); no UIKit, SwiftUI or WidgetKit.

Conventions:

- JSON field names are mapped with explicit `CodingKeys` (snake_case on the
  wire, camelCase in Swift). Always decode with `SlurmJSON`, which sets the
  ISO 8601 date strategy.
- `JobState`, `NodeState` and `CardState` decode unknown raw values as
  `.unknown`.
- `SlurmClient` methods throw `FetchError` only. `OIDCClient` methods throw
  `OIDCError` only.
- The `user` of a fetch is a `UserScope`. `.configured` (the default) sends
  `settings.username` when one is set, `.named("bob")` sends that name, and
  `.everyone` sends `*`, the whole cluster's view. `SlurmClient` never
  applies `settings.defaultPartition`; pass the partition yourself.
- `SnapshotLoader` caches per server and per user: its keys carry a tag of
  `settings.serverURL` and the username the scope stands for, so a snapshot
  is never shown for another server or another user.
- `OIDCClient.authorizationURL` adds `prompt=consent` when the scopes
  include `offline_access`.
- `GpuCard.temperatureC` and `GpuCard.powerW` are `Double?` (the contract
  shows whole numbers; fractional values decode as well).
- Sample user names are `alice`, `bob`, `carol`, `dave`, `erin`.

## Usage: `SnapshotLoader`

```swift
// In a widget timeline provider. `live()` reads the shared settings, the
// keychain and the file cache in the app group container.
let loader = SnapshotLoader.live()
let settings = ServerSettings.load()
let content: WidgetContent<QueueData> = await loader.queue(partition: settings.defaultPartition)

switch content {
case .live(let queue, let generatedAt):
    // normal layout; header time: Format.clockTime(generatedAt, timeZone: .current)
    _ = (queue.running, queue.pending, queue.mineLine)
case .stale(let queue, let generatedAt):
    // normal layout in stale grey; header: Format.asOf(generatedAt, timeZone: .current)
    _ = (queue, generatedAt)
case .vpnNeeded(let last, let generatedAt):
    // "VPN needed"; `last` and `generatedAt` are nil when nothing was ever cached
    _ = (last, generatedAt)
case .signInNeeded:
    break   // "Sign in needed"
case .notConfigured:
    break   // no server URL set; open the app
}

// Previews, placeholders, screenshot tests:
let preview: WidgetContent<GpuData> = .live(SampleData.gpu.data, generatedAt: SampleData.generatedAt)

// Tests: inject everything.
let testLoader = SnapshotLoader(client: myStubFetcher, cache: InMemorySnapshotCache(), now: { SampleData.generatedAt })
```

## Usage: OIDC sign-in

```swift
// 1. Save the server URL, then ask the server which methods it offers.
var settings = ServerSettings.load()
settings.serverURL = ServerSettings.parseServerURL("slurm.example.org")
settings.save()

let store = KeychainCredentialStore()
let client = SlurmClient(settings: settings, credentials: store)
let auth = try await client.authConfig()          // throws FetchError
guard let oidcConfig = auth.oidc else { return }  // token-only server

// 2. Discovery, PKCE and state.
let oidc = OIDCClient()
let request = try await oidc.prepareAuthorization(config: oidcConfig)   // throws OIDCError

// 3. The app runs ASWebAuthenticationSession(url: request.url,
//    callbackURLScheme: SlurmKitConstants.oidcCallbackScheme) and receives `callbackURL`.

// 4. Exchange the code and store the tokens.
let tokens = try await oidc.completeAuthorization(request, callbackURL: callbackURL)
try store.save(.oidc(tokens))

// 5. Optional: learn the Slurm username.
let identity = try await client.me()
settings.username = identity.username ?? settings.username
settings.save()

// Static token instead:  try store.save(.staticToken(token))
// Sign out:              try store.clear()
// Refreshing is automatic: on a 401 with OIDC credentials that hold a refresh
// token, SlurmClient refreshes once, stores the new tokens and retries once.
```

## Constants.swift

```swift
public enum SlurmKitConstants
    public static let appGroup = "group.de.awi.slurm-monitor"
    public static let keychainService = "de.awi.slurm-monitor.credentials"
    public static let oidcRedirectURI = "de.awi.slurm-monitor:/oauth/callback"
    public static let oidcCallbackScheme = "de.awi.slurm-monitor"
    public static let apiBasePath = "/api/v1"
    public static let schemaVersion = 1
    public static let requestTimeout: TimeInterval = 8
    public static let staleAfter: TimeInterval = 600

public enum SlurmJSON
    public static func makeDecoder() -> JSONDecoder
    public static func makeEncoder() -> JSONEncoder
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
    public static func encode<T: Encodable>(_ value: T) throws -> Data

public enum WidgetFamilyKind: String, Codable, Sendable, CaseIterable
    case queue
    case nodes
    case qos
    case gpu
    case runners
    public var path: String
    public var title: String
```

## Models.swift

```swift
public struct Snapshot<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable
    public var schemaVersion: Int
    public var cluster: String
    public var generatedAt: Date
    public var stale: Bool
    public var data: T
    public init(schemaVersion: Int = SlurmKitConstants.schemaVersion, cluster: String, generatedAt: Date, stale: Bool = false, data: T)

public enum JobState: String, Codable, Sendable, Equatable, CaseIterable
    case running = "R"
    case pending = "PD"
    case unknown
    public init(from decoder: Decoder) throws

public enum NodeState: String, Codable, Sendable, Equatable, CaseIterable
    case allocated
    case idle
    case drained
    case down
    case unknown
    public init(from decoder: Decoder) throws

public enum CardState: String, Codable, Sendable, Equatable, CaseIterable
    case busy
    case idleAllocated = "idle_allocated"
    case allocated
    case free
    case drained
    case down
    case unknown
    public init(from decoder: Decoder) throws
    public var isAllocated: Bool

public struct JobCounts: Codable, Sendable, Equatable
    public var running: Int
    public var pending: Int
    public init(running: Int, pending: Int)

public struct ReasonCount: Codable, Sendable, Equatable, Identifiable
    public var reason: String
    public var count: Int
    public var id: String { reason }
    public init(reason: String, count: Int)

public struct JobSummary: Codable, Sendable, Equatable, Identifiable
    public var jobId: Int
    public var name: String
    public var state: JobState
    public var partition: String
    public var resources: String
    public var elapsedSeconds: Int
    public var timeLimitSeconds: Int?
    public var estimatedStart: Date?
    public var reason: String?
    public var id: Int { jobId }
    public init(jobId: Int, name: String, state: JobState, partition: String, resources: String, elapsedSeconds: Int, timeLimitSeconds: Int?, estimatedStart: Date?, reason: String?)

public struct QueueHistoryPoint: Codable, Sendable, Equatable
    public var t: Date
    public var running: Int
    public var pending: Int
    public init(t: Date, running: Int, pending: Int)

public struct QueueData: Codable, Sendable, Equatable
    public var partition: String?
    public var qos: String?
    public var user: String?
    public var running: Int
    public var pending: Int
    public var mine: JobCounts?
    public var pendingByReason: [ReasonCount]
    public var myJobsTotal: Int
    public var myJobs: [JobSummary]
    public var history: [QueueHistoryPoint]
    public init(partition: String?, qos: String?, user: String?, running: Int, pending: Int, mine: JobCounts?, pendingByReason: [ReasonCount], myJobsTotal: Int, myJobs: [JobSummary], history: [QueueHistoryPoint])

public struct NodeInfo: Codable, Sendable, Equatable, Identifiable
    public var name: String
    public var state: NodeState
    public var id: String { name }
    public init(name: String, state: NodeState)

public struct PartitionNodes: Codable, Sendable, Equatable, Identifiable
    public var name: String
    public var total: Int
    public var allocated: Int
    public var idle: Int
    public var drained: Int
    public var down: Int
    public var nodes: [NodeInfo]
    public var id: String { name }
    public init(name: String, total: Int, allocated: Int, idle: Int, drained: Int, down: Int, nodes: [NodeInfo])

public struct NodesData: Codable, Sendable, Equatable
    public var total: Int
    public var allocated: Int
    public var idle: Int
    public var drained: Int
    public var down: Int
    public var partitions: [PartitionNodes]
    public init(total: Int, allocated: Int, idle: Int, drained: Int, down: Int, partitions: [PartitionNodes])

public struct QosEntry: Codable, Sendable, Equatable, Identifiable
    public var name: String
    public var cpusInUse: Int
    public var cpuLimit: Int?
    public var runningJobs: Int
    public var pendingJobs: Int
    public var maxWallSeconds: Int?
    public var id: String { name }
    public init(name: String, cpusInUse: Int, cpuLimit: Int?, runningJobs: Int, pendingJobs: Int, maxWallSeconds: Int?)

public struct QosData: Codable, Sendable, Equatable
    public var user: String?
    public var account: String?
    public var fairshare: Double?
    public var qos: [QosEntry]
    public init(user: String?, account: String?, fairshare: Double?, qos: [QosEntry])

public struct GpuTypeCount: Codable, Sendable, Equatable, Identifiable
    public var type: String
    public var label: String
    public var total: Int
    public var allocated: Int
    public var id: String { type }
    public init(type: String, label: String, total: Int, allocated: Int)

public struct GpuCard: Codable, Sendable, Equatable, Identifiable
    public var index: Int
    public var state: CardState
    public var utilisation: Double?
    public var memoryUsedMib: Int?
    public var memoryTotalMib: Int?
    public var temperatureC: Double?
    public var powerW: Double?
    public var user: String?
    public var id: Int { index }
    public init(index: Int, state: CardState, utilisation: Double?, memoryUsedMib: Int?, memoryTotalMib: Int?, temperatureC: Double?, powerW: Double?, user: String?)

public struct GpuNode: Codable, Sendable, Equatable, Identifiable
    public var name: String
    public var type: String
    public var state: NodeState
    public var cards: [GpuCard]
    public var id: String { name }
    public init(name: String, type: String, state: NodeState, cards: [GpuCard])

public struct GpuUserCards: Codable, Sendable, Equatable, Identifiable
    public var user: String
    public var cards: Int
    public var id: String { user }
    public init(user: String, cards: Int)

public struct GpuHistoryPoint: Codable, Sendable, Equatable
    public var t: Date
    public var allocatedFraction: Double
    public var utilisation: Double?
    public init(t: Date, allocatedFraction: Double, utilisation: Double?)

public struct GpuData: Codable, Sendable, Equatable
    public var metricsAvailable: Bool
    public var total: Int
    public var allocated: Int
    public var idleAllocated: Int?
    public var pendingJobs: Int
    public var longestWaitSeconds: Int?
    public var types: [GpuTypeCount]
    public var nodes: [GpuNode]
    public var topUsers: [GpuUserCards]
    public var history: [GpuHistoryPoint]
    public init(metricsAvailable: Bool, total: Int, allocated: Int, idleAllocated: Int?, pendingJobs: Int, longestWaitSeconds: Int?, types: [GpuTypeCount], nodes: [GpuNode], topUsers: [GpuUserCards], history: [GpuHistoryPoint])

public struct CiRunners: Codable, Sendable, Equatable
    public var runnersAlive: Int
    public var jobsWaiting: Int
    public var oldestWaitSeconds: Int?
    public init(runnersAlive: Int, jobsWaiting: Int, oldestWaitSeconds: Int?)

public struct DaskCluster: Codable, Sendable, Equatable, Identifiable
    public var id: String
    public var owner: String
    public var schedulerAlive: Bool
    public var workersRunning: Int
    public var workersRequested: Int
    public var walltimeLeftSeconds: Int?
    public init(id: String, owner: String, schedulerAlive: Bool, workersRunning: Int, workersRequested: Int, walltimeLeftSeconds: Int?)

public struct DaskRunners: Codable, Sendable, Equatable
    public var clusters: [DaskCluster]
    public init(clusters: [DaskCluster])

public struct JupyterHubRunners: Codable, Sendable, Equatable
    public var sessions: Int
    public var withGpu: Int
    public var nearWalltime: Int
    public init(sessions: Int, withGpu: Int, nearWalltime: Int)

public struct ExtraRunnerKind: Codable, Sendable, Equatable, Identifiable
    public var key: String
    public var label: String
    public var running: Int
    public var pending: Int
    public var id: String { key }
    public init(key: String, label: String, running: Int, pending: Int)

public struct RunnersData: Codable, Sendable, Equatable
    public var ci: CiRunners
    public var dask: DaskRunners
    public var jupyterhub: JupyterHubRunners
    public var extra: [ExtraRunnerKind]
    public init(ci: CiRunners, dask: DaskRunners, jupyterhub: JupyterHubRunners, extra: [ExtraRunnerKind])

public struct HealthStatus: Codable, Sendable, Equatable
    public var status: String
    public var version: String
    public var schemaVersion: Int
    public var lastPollAt: Date?
    public var lastPollOk: Bool?
    public init(status: String, version: String, schemaVersion: Int, lastPollAt: Date?, lastPollOk: Bool?)

public struct OIDCConfig: Codable, Sendable, Equatable
    public var issuer: String
    public var clientId: String
    public var scopes: [String]
    public init(issuer: String, clientId: String, scopes: [String])

public struct AuthConfig: Codable, Sendable, Equatable
    public var methods: [String]
    public var oidc: OIDCConfig?
    public init(methods: [String], oidc: OIDCConfig?)
    public var supportsToken: Bool { methods.contains("token") }
    public var supportsOIDC: Bool { methods.contains("oidc") && oidc != nil }

public struct Identity: Codable, Sendable, Equatable
    public var method: String
    public var subject: String?
    public var username: String?
    public init(method: String, subject: String?, username: String?)
```

## ServerSettings.swift

```swift
public struct ServerSettings: Codable, Sendable, Equatable
    public var serverURL: URL?
    public var username: String?
    public var defaultPartition: String?
    public init(serverURL: URL? = nil, username: String? = nil, defaultPartition: String? = nil)
    public var isConfigured: Bool { serverURL != nil }
    public static func sharedDefaults() -> UserDefaults
    public static func load() -> ServerSettings
    public static func load(from defaults: UserDefaults) -> ServerSettings
    public func save()
    public func save(to defaults: UserDefaults)
    public static func parseServerURL(_ text: String) -> URL?
```

## Credentials.swift

```swift
public struct OIDCTokens: Codable, Sendable, Equatable
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public init(accessToken: String, refreshToken: String?, expiresAt: Date?)

public enum Credentials: Codable, Sendable, Equatable
    case staticToken(String)
    case oidc(OIDCTokens)
    public var bearerToken: String

public protocol CredentialStoring: Sendable
    func load() throws -> Credentials?
    func save(_ credentials: Credentials) throws
    func clear() throws

public struct KeychainError: Error, Sendable, Equatable
    public var status: Int32
    public init(status: Int32)

public struct KeychainCredentialStore: CredentialStoring
    public var service: String
    public var account: String
    public var accessGroup: String?
    public init(service: String = SlurmKitConstants.keychainService, account: String = "default", accessGroup: String? = SlurmKitConstants.appGroup)
    public func load() throws -> Credentials?
    public func save(_ credentials: Credentials) throws
    public func clear() throws

public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable
    public init(_ credentials: Credentials? = nil)
    public func load() throws -> Credentials?
    public func save(_ credentials: Credentials) throws
    public func clear() throws
```

## Transport.swift

```swift
public protocol HTTPTransport: Sendable
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

public struct URLSessionTransport: HTTPTransport
    public let session: URLSession
    public init(session: URLSession = URLSessionTransport.makeSession())
    public static func makeSession() -> URLSession
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
```

## SlurmClient.swift

```swift
public enum FetchError: Error, Sendable, Equatable
    case unreachable
    case unauthorized
    case noCredentials
    case noData
    case decoding(String)
    case notConfigured

public enum UserScope: Sendable, Equatable
    case configured
    case named(String)
    case everyone
    public static let everyoneValue = "*"
    public func username(settings: ServerSettings) -> String?
    public func queryValue(settings: ServerSettings) -> String?

public protocol SlurmFetching: Sendable
    var settings: ServerSettings { get }
    func queue(partition: String?, user: UserScope, qos: String?) async throws -> Snapshot<QueueData>
    func nodes(partition: String?) async throws -> Snapshot<NodesData>
    func qos(user: UserScope) async throws -> Snapshot<QosData>
    func gpu() async throws -> Snapshot<GpuData>
    func runners(user: UserScope) async throws -> Snapshot<RunnersData>

public struct SlurmClient: SlurmFetching
    public let settings: ServerSettings
    public init(settings: ServerSettings, credentials: any CredentialStoring, transport: any HTTPTransport = URLSessionTransport())
    public static func live() -> SlurmClient
    public func queue(partition: String? = nil, user: UserScope = .configured, qos: String? = nil) async throws -> Snapshot<QueueData>
    public func nodes(partition: String? = nil) async throws -> Snapshot<NodesData>
    public func qos(user: UserScope = .configured) async throws -> Snapshot<QosData>
    public func gpu() async throws -> Snapshot<GpuData>
    public func runners(user: UserScope = .configured) async throws -> Snapshot<RunnersData>
    public func health() async throws -> HealthStatus
    public func authConfig() async throws -> AuthConfig
    public func me() async throws -> Identity
    public func makeRequest(path: String, query: [(String, String?)], bearerToken: String?) throws -> URLRequest
```

## OIDC.swift

```swift
public struct PKCE: Sendable, Equatable
    public var verifier: String
    public var challenge: String
    public init(verifier: String)
    public static func generate() -> PKCE
    public static func challenge(for verifier: String) -> String
    public static func randomURLSafeString(byteCount: Int) -> String
    public static func base64URL(_ data: Data) -> String

public struct OIDCDiscovery: Codable, Sendable, Equatable
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public init(authorizationEndpoint: URL, tokenEndpoint: URL)

public struct OIDCAuthorizationRequest: Sendable, Equatable
    public var url: URL
    public var state: String
    public var pkce: PKCE
    public var discovery: OIDCDiscovery
    public var config: OIDCConfig
    public init(url: URL, state: String, pkce: PKCE, discovery: OIDCDiscovery, config: OIDCConfig)

public enum OIDCError: Error, Sendable, Equatable
    case invalidConfiguration
    case network
    case http(Int)
    case decoding(String)
    case stateMismatch
    case missingCode
    case authorizationFailed(String)

public struct OIDCClient: Sendable
    public init(transport: any HTTPTransport = URLSessionTransport())
    public static func discoveryURL(issuer: String) -> URL?
    public func discover(issuer: String) async throws -> OIDCDiscovery
    public static func authorizationURL(discovery: OIDCDiscovery, config: OIDCConfig, pkce: PKCE, state: String, redirectURI: String = SlurmKitConstants.oidcRedirectURI) -> URL?
    public func prepareAuthorization(config: OIDCConfig) async throws -> OIDCAuthorizationRequest
    public static func authorizationCode(fromCallback callbackURL: URL, expectedState: String) throws -> String
    public func completeAuthorization(_ request: OIDCAuthorizationRequest, callbackURL: URL, now: Date = Date()) async throws -> OIDCTokens
    public func exchangeCode(_ code: String, verifier: String, discovery: OIDCDiscovery, clientId: String, redirectURI: String = SlurmKitConstants.oidcRedirectURI, now: Date = Date()) async throws -> OIDCTokens
    public func refresh(refreshToken: String, discovery: OIDCDiscovery, clientId: String, now: Date = Date()) async throws -> OIDCTokens
    public static func formEncode(_ fields: [(String, String)]) -> String
```

## SnapshotCache.swift

```swift
public struct CachedSnapshot: Codable, Sendable, Equatable
    public var payload: Data
    public var fetchedAt: Date
    public init(payload: Data, fetchedAt: Date)

public protocol SnapshotCaching: Sendable
    func store(_ payload: Data, key: String, fetchedAt: Date)
    func load(key: String) -> CachedSnapshot?
    func removeAll()

public enum SnapshotCacheKey
    public static func make(family: WidgetFamilyKind, parameters: [String: String?] = [:], server: URL? = nil) -> String
    public static func serverTag(_ server: URL) -> String
    public static func userParameters(_ scope: UserScope, settings: ServerSettings) -> [String: String?]

public struct FileSnapshotCache: SnapshotCaching
    public let directory: URL
    public init(directory: URL)
    public init()
    public static func defaultDirectory() -> URL
    public func store(_ payload: Data, key: String, fetchedAt: Date)
    public func load(key: String) -> CachedSnapshot?
    public func removeAll()
    public func fileURL(key: String) -> URL

public final class InMemorySnapshotCache: SnapshotCaching, @unchecked Sendable
    public init() {}
    public func store(_ payload: Data, key: String, fetchedAt: Date)
    public func load(key: String) -> CachedSnapshot?
    public func removeAll()
```

## SnapshotLoader.swift

```swift
public enum WidgetContent<T>
    case live(T, generatedAt: Date)
    case stale(T, generatedAt: Date)
    case vpnNeeded(last: T?, generatedAt: Date?)
    case signInNeeded
    case notConfigured
    public var value: T?
    public var generatedAt: Date?
    public var isStale: Bool
    public func map<U>(_ transform: (T) -> U) -> WidgetContent<U>

extension WidgetContent: Sendable where T: Sendable

extension WidgetContent: Equatable where T: Equatable

public struct SnapshotLoader: Sendable
    public init(client: any SlurmFetching, cache: any SnapshotCaching, now: @escaping @Sendable () -> Date = { Date() })
    public static func live() -> SnapshotLoader
    public func queue(partition: String? = nil, user: UserScope = .configured, qos: String? = nil) async -> WidgetContent<QueueData>
    public func nodes(partition: String? = nil) async -> WidgetContent<NodesData>
    public func qos(user: UserScope = .configured) async -> WidgetContent<QosData>
    public func gpu() async -> WidgetContent<GpuData>
    public func runners(user: UserScope = .configured) async -> WidgetContent<RunnersData>
    public func load<T: Codable & Sendable & Equatable>(key: String, fetch: () async throws -> Snapshot<T>) async -> WidgetContent<T>
    public func cachedSnapshot<T: Codable & Sendable & Equatable>(key: String) -> Snapshot<T>?
    public static func content<T: Codable & Sendable & Equatable>(for snapshot: Snapshot<T>, now: Date) -> WidgetContent<T>
    public static func isStale<T: Codable & Sendable & Equatable>(_ snapshot: Snapshot<T>, now: Date) -> Bool
```

## Formatters.swift

```swift
public enum Format
    public static let dash = "—"
    public static func hoursMinutes(seconds: Int) -> String
    public static func hoursMinutes(seconds: Int?) -> String
    public static func durationWords(seconds: Int) -> String
    public static func durationWords(seconds: Int?) -> String
    public static func elapsedOverLimit(elapsedSeconds: Int, limitSeconds: Int?) -> String
    public static func compactCount(_ value: Int) -> String
    public static func countOverLimit(_ value: Int, limit: Int?) -> String
    public static func percentValue(_ fraction: Double) -> Int
    public static func percent(_ fraction: Double) -> String
    public static func percent(_ fraction: Double?) -> String
    public static func ratio(_ part: Int, _ whole: Int) -> String
    public static func queueLine(running: Int, pending: Int) -> String
    public static func queueLine(_ counts: JobCounts?) -> String
    public static func clockTime(_ date: Date, timeZone: TimeZone) -> String
    public static func estimatedStart(_ date: Date, timeZone: TimeZone) -> String
    public static func asOf(_ date: Date, timeZone: TimeZone) -> String
    public static func memoryGigabytes(mib: Int) -> String
    public static func memoryGigabytes(mib: Int?) -> String
    public static func temperature(celsius: Double?) -> String
    public static func power(watts: Double?) -> String
    public static func fairshare(_ value: Double?) -> String
    public static func cardText(_ card: GpuCard) -> String

public struct NodeStateCounts: Sendable, Equatable
    public var allocated: Int
    public var idle: Int
    public var drained: Int
    public var down: Int
    public init(allocated: Int, idle: Int, drained: Int, down: Int)
    public var total: Int { allocated + idle + drained + down }
    public var fractions: [Double]

extension NodesData
    public var allocatedFraction: Double
    public var stateCounts: NodeStateCounts

extension PartitionNodes
    public var allocatedFraction: Double
    public var stateCounts: NodeStateCounts
    public var allocatedText: String

extension QosEntry
    public var usedFraction: Double?
    public var isNearLimit: Bool
    public var usageText: String

extension QueueData
    public var nextPendingStart: JobSummary?
    public func moreJobsCount(shown: Int) -> Int
    public var mineLine: String

extension JobSummary
    public var elapsedFraction: Double?

extension GpuTypeCount
    public var allocatedText: String
    public var allocatedFraction: Double

extension GpuCard
    public var memoryFraction: Double?

public struct GpuTypeGroup: Sendable, Equatable, Identifiable
    public var type: GpuTypeCount
    public var nodes: [GpuNode]
    public var id: String { type.type }
    public init(type: GpuTypeCount, nodes: [GpuNode])
    public var cardsPerNode: Int
    public var heading: String

extension GpuData
    public var allocatedFraction: Double
    public var allocatedText: String
    public var typeGroups: [GpuTypeGroup]
    public var showsIdleAllocated: Bool
    public var sparklineValues: [Double]
    public var sparklineLabel: String
    public var currentSparklineValue: Double?
    public var pendingLine: String

extension DaskCluster
    public var label: String
    public var workersText: String
    public var walltimeLeftText: String
    public var isNearWalltime: Bool

extension CiRunners
    public var oldestWaitText: String
```

## SampleData.swift

```swift
public enum SampleData
    public static let cluster = "albedo"
    public static let generatedAt: Date   // 2026-10-01T12:32:07Z
    public static let queue: Snapshot<QueueData>
    public static let nodes: Snapshot<NodesData>
    public static let qos: Snapshot<QosData>
    public static let gpu: Snapshot<GpuData>
    public static let gpuNoMetrics: Snapshot<GpuData>
    public static let runners: Snapshot<RunnersData>
    public static let health: HealthStatus
    public static let authConfig: AuthConfig
    public static let settings: ServerSettings   // https://slurm.example.org, user "alice"
```
