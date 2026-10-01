import Foundation
import SlurmKit
import SwiftUI
import WidgetKit

/// What the app knows about how the server lets users sign in.
enum AuthConfigState: Equatable {
    case unknown
    case loading
    case loaded(AuthConfig)
    case failed
}

/// What the app knows about the stored sign-in.
enum SignInStatus: Equatable {
    case unknown
    case checking
    case signedOut
    case signedIn(Identity)
    /// The server refused the stored credentials.
    case refused
    /// Credentials are stored, but the server could not be asked about them.
    case unverified(oidc: Bool)

    /// True when credentials are stored on the device.
    var hasCredentials: Bool {
        switch self {
        case .signedIn, .refused, .unverified:
            return true
        case .unknown, .checking, .signedOut:
            return false
        }
    }
}

/// The outcome of asking the health endpoint.
enum ConnectionTest: Equatable {
    case idle
    case running
    case reachable(HealthStatus)
    case failed(String)
}

/// The state shared by all sections: which one is shown, the settings, and
/// the sign-in. Creating it reads the stored settings and nothing else.
@MainActor
final class AppModel: ObservableObject {
    @Published var selection: AppSection?
    @Published private(set) var settings: ServerSettings
    /// Counts changes to settings and credentials; sections reload when it changes.
    @Published private(set) var revision: Int = 0
    @Published private(set) var knownPartitions: [String]

    @Published private(set) var authConfigState: AuthConfigState = .unknown
    @Published private(set) var signInStatus: SignInStatus = .unknown
    @Published private(set) var serverHealth: HealthStatus?
    @Published private(set) var isSigningIn = false
    /// A plain sentence about the last sign-in action that failed.
    @Published var signInMessage: String?

    let credentialStore: any CredentialStoring
    private let webAuthenticator = WebAuthenticator()
    private let localDefaults: UserDefaults
    private static let knownPartitionsKey = "known_partitions"

    init(
        settings: ServerSettings = ServerSettings.load(),
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        localDefaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.credentialStore = credentialStore
        self.localDefaults = localDefaults
        self.knownPartitions = localDefaults.stringArray(forKey: AppModel.knownPartitionsKey) ?? []
    }

    // MARK: Fetching

    func makeClient() -> SlurmClient {
        SlurmClient(settings: settings, credentials: credentialStore)
    }

    func makeLoader() -> SnapshotLoader {
        SnapshotLoader(client: makeClient(), cache: FileSnapshotCache())
    }

    // MARK: Links

    func handle(url: URL) {
        guard let link = IncomingLink.parse(url) else { return }
        switch link {
        case .section(let section):
            selection = section
        case .oauthCallback(let callbackURL):
            // The web session normally intercepts the callback itself; this
            // covers the case where the system hands it to the app instead.
            _ = webAuthenticator.deliver(callbackURL: callbackURL)
        }
    }

    // MARK: Settings

    /// Stores new settings, if they differ, and tells the widgets. A changed
    /// server address also removes the stored sign-in: a token or a
    /// Helmholtz AAI sign-in belongs to one server and must not be sent to
    /// another.
    func applySettings(_ newSettings: ServerSettings) {
        guard newSettings != settings else { return }
        let serverChanged = newSettings.serverURL != settings.serverURL
        settings = newSettings
        newSettings.save()
        if serverChanged {
            let cleared: Bool = (try? credentialStore.clear()) != nil
            // Cached snapshots and partition names belong to the old server.
            FileSnapshotCache().removeAll()
            setKnownPartitions([])
            authConfigState = .unknown
            signInStatus = cleared ? .signedOut : .unknown
            serverHealth = nil
            signInMessage = cleared ? nil : "The sign-in for the previous server could not be removed. Sign out before using this server."
        }
        settingsOrCredentialsDidChange()
    }

    private func settingsOrCredentialsDidChange() {
        revision += 1
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Partitions

    /// The names offered by the partition filter: those the server reported,
    /// the default from the settings, and the one currently chosen.
    func partitionChoices(including current: String?) -> [String] {
        var names = knownPartitions
        for extra in [settings.defaultPartition, current] {
            if let extra = extra, !extra.isEmpty, !names.contains(extra) {
                names.append(extra)
            }
        }
        return names
    }

    /// Remembers the partition names of an unfiltered nodes snapshot.
    func notePartitions(_ nodes: NodesData) {
        let names = nodes.partitions.map { $0.name }
        if !names.isEmpty && names != knownPartitions {
            setKnownPartitions(names)
        }
    }

    /// Asks the nodes endpoint once for the partition names, when none are known.
    func learnPartitionsIfNeeded() async {
        guard knownPartitions.isEmpty, settings.isConfigured else { return }
        let content = await makeLoader().nodes(partition: nil)
        switch content {
        case .live(let nodes, _), .stale(let nodes, _):
            notePartitions(nodes)
        case .vpnNeeded, .signInNeeded, .notConfigured:
            break
        }
    }

    private func setKnownPartitions(_ names: [String]) {
        knownPartitions = names
        localDefaults.set(names, forKey: AppModel.knownPartitionsKey)
    }

    // MARK: Server facts

    /// Asks the health endpoint of the given address.
    func testConnection(to url: URL) async -> ConnectionTest {
        let client = SlurmClient(settings: ServerSettings(serverURL: url), credentials: credentialStore)
        do {
            let health = try await client.health()
            if url == settings.serverURL {
                serverHealth = health
            }
            return .reachable(health)
        } catch let error as FetchError {
            switch error {
            case .decoding:
                return .failed("The address answered, but not as a Slurm Monitor server.")
            case .noData:
                return .failed("The server is running but has not polled Slurm yet.")
            default:
                return .failed("The server could not be reached. Check the address and the VPN.")
            }
        } catch {
            return .failed("The server could not be reached. Check the address and the VPN.")
        }
    }

    /// Loads the sign-in methods and the health of the configured server,
    /// then checks the stored sign-in. Does nothing without a server address.
    func refreshServerFacts() async {
        guard settings.isConfigured else {
            authConfigState = .unknown
            serverHealth = nil
            signInStatus = .unknown
            return
        }
        let asked = settings.serverURL
        let client = makeClient()
        if case .loaded = authConfigState {
            // Keep what is shown while asking again.
        } else {
            authConfigState = .loading
        }
        let newState: AuthConfigState
        do {
            let config = try await client.authConfig()
            newState = .loaded(config)
        } catch {
            newState = .failed
        }
        let health = try? await client.health()
        guard asked == settings.serverURL else { return }
        authConfigState = newState
        if let health = health {
            serverHealth = health
        }
        await refreshSignInStatus()
    }

    /// Looks at the stored credentials and asks the server who they belong to.
    @discardableResult
    func refreshSignInStatus() async -> Identity? {
        let loaded = try? credentialStore.load()
        guard let stored = loaded else {
            signInStatus = .signedOut
            return nil
        }
        var storedIsOIDC = false
        if case .oidc = stored {
            storedIsOIDC = true
        }
        guard settings.isConfigured else {
            signInStatus = .unverified(oidc: storedIsOIDC)
            return nil
        }
        if !signInStatus.hasCredentials {
            signInStatus = .checking
        }
        do {
            let identity = try await makeClient().me()
            signInStatus = .signedIn(identity)
            return identity
        } catch let error as FetchError {
            switch error {
            case .unauthorized:
                signInStatus = .refused
            case .noCredentials:
                signInStatus = .signedOut
            default:
                signInStatus = .unverified(oidc: storedIsOIDC)
            }
        } catch {
            signInStatus = .unverified(oidc: storedIsOIDC)
        }
        return nil
    }

    // MARK: Signing in and out

    /// Stores a static token and checks it against the server.
    func saveStaticToken(_ text: String) async {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            signInMessage = "Enter the token first."
            return
        }
        signInMessage = nil
        do {
            try credentialStore.save(.staticToken(token))
        } catch {
            signInMessage = "The token could not be stored on this device."
            return
        }
        settingsOrCredentialsDidChange()
        await refreshSignInStatus()
        if signInStatus == .refused {
            signInMessage = "The server did not accept this token."
        }
    }

    /// The Helmholtz AAI sign-in: authorisation code flow with PKCE.
    func signInWithHelmholtz() async {
        guard !isSigningIn else { return }
        guard case .loaded(let config) = authConfigState, config.supportsOIDC, let oidcConfig = config.oidc else {
            signInMessage = "This server does not offer Helmholtz AAI sign-in."
            return
        }
        isSigningIn = true
        signInMessage = nil
        defer { isSigningIn = false }

        let oidc = OIDCClient()
        do {
            // Discovery, PKCE verifier and challenge, state.
            let request = try await oidc.prepareAuthorization(config: oidcConfig)
            // The browser sheet; returns the redirect to de.awi.slurm-monitor:/oauth/callback.
            let callbackURL = try await webAuthenticator.run(
                url: request.url,
                callbackScheme: SlurmKitConstants.oidcCallbackScheme
            )
            // Checks the state parameter, then exchanges the code with the verifier.
            let tokens = try await oidc.completeAuthorization(request, callbackURL: callbackURL)
            try credentialStore.save(.oidc(tokens))
        } catch let error as OIDCError {
            signInMessage = AppModel.message(for: error)
            return
        } catch let error as WebAuthenticationError {
            signInMessage = AppModel.message(for: error)
            return
        } catch {
            signInMessage = "The sign-in could not be stored on this device."
            return
        }

        settingsOrCredentialsDidChange()
        let identity = await refreshSignInStatus()
        if let username = identity?.username, !username.isEmpty, username != settings.username {
            // The server knows the Slurm username of the signed-in user.
            var updated = settings
            updated.username = username
            applySettings(updated)
        }
        if signInStatus == .refused {
            signInMessage = "Helmholtz AAI signed you in, but the server did not accept the sign-in. Your account may not be entitled to use this cluster."
        }
    }

    /// Removes the stored credentials and the cached snapshots.
    func signOut() {
        signInMessage = nil
        do {
            try credentialStore.clear()
        } catch {
            signInMessage = "The stored sign-in could not be removed."
            return
        }
        FileSnapshotCache().removeAll()
        signInStatus = .signedOut
        settingsOrCredentialsDidChange()
    }

    private static func message(for error: OIDCError) -> String {
        switch error {
        case .invalidConfiguration:
            return "The server's sign-in configuration is not usable. Tell the server's administrator."
        case .network:
            return "Helmholtz AAI could not be reached. Check the network connection and try again."
        case .http(let status):
            return "Helmholtz AAI answered with an error (HTTP \(status))."
        case .decoding:
            return "The answer from Helmholtz AAI could not be read."
        case .stateMismatch:
            return "The sign-in answer did not belong to this request. Nothing was stored; try again."
        case .missingCode:
            return "The sign-in answer carried no authorisation code. Try again."
        case .authorizationFailed(let reason):
            return "Helmholtz AAI refused the sign-in (\(reason))."
        }
    }

    private static func message(for error: WebAuthenticationError) -> String {
        switch error {
        case .cancelled:
            return "The sign-in was cancelled."
        case .couldNotStart:
            return "The sign-in page could not be opened."
        case .failed(let reason):
            if reason.isEmpty {
                return "The sign-in did not finish."
            }
            return "The sign-in did not finish: \(reason)"
        }
    }
}
