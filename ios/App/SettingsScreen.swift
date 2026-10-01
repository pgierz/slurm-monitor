import SlurmKit
import SwiftUI

/// Server address, user, sign-in and a short About block.
struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel

    @State private var address = ""
    @State private var username = ""
    @State private var partition = ""
    @State private var token = ""
    @State private var connectionTest: ConnectionTest = .idle
    @State private var didFillFields = false

    var body: some View {
        Form {
            serverSection
            userSection
            signInSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            fillFieldsOnce()
        }
        .onChange(of: model.settings) { _, newSettings in
            // A sign-in may have filled in the username.
            fillFields(from: newSettings)
        }
        .task {
            await model.refreshServerFacts()
        }
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            TextField("slurm.example.org", text: $address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Server address")
                .onChange(of: address) { _, _ in
                    connectionTest = .idle
                }
            if let problem = addressProblem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Palette.down)
            } else if let advice = addressAdvice {
                Text(advice)
                    .font(.footnote)
                    .foregroundStyle(Palette.amber)
            }
            Button("Test connection") {
                runConnectionTest()
            }
            .disabled(parsedAddress == nil || addressProblem != nil || connectionTest == .running)
            connectionTestResult
        } header: {
            Text("Server")
        } footer: {
            Text("The address of the Slurm Monitor server, without a path. https is assumed when no scheme is given.")
        }
        .listRowBackground(Palette.panel)
    }

    @ViewBuilder
    private var connectionTestResult: some View {
        switch connectionTest {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("Asking the server")
                    .foregroundStyle(Palette.secondary)
            }
        case .reachable(let health):
            VStack(alignment: .leading, spacing: 4) {
                Text("Reachable. Server version \(health.version).")
                    .foregroundStyle(Palette.primary)
                Text(SettingsText.lastPoll(health))
                    .font(.footnote)
                    .foregroundStyle(health.lastPollOk == false ? Palette.amber : Palette.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(Palette.down)
        }
    }

    // MARK: User

    private var userSection: some View {
        Section {
            TextField("Slurm username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Default partition (optional)", text: $partition)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") {
                save()
            }
            .disabled(!canSave)
        } header: {
            Text("User")
        } footer: {
            Text("The username selects whose jobs count as mine. The default partition is preselected in the Queue and Nodes sections and offered to the widgets.")
        }
        .listRowBackground(Palette.panel)
    }

    // MARK: Sign-in

    private var signInSection: some View {
        Section {
            LabeledContent("Status") {
                Text(SettingsText.status(model.signInStatus))
                    .multilineTextAlignment(.trailing)
            }
            signInMethods
            if let message = model.signInMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.down)
            }
            if model.signInStatus.hasCredentials {
                Button("Sign out", role: .destructive) {
                    model.signOut()
                }
            }
        } header: {
            Text("Sign-in")
        } footer: {
            signInFooter
        }
        .listRowBackground(Palette.panel)
    }

    @ViewBuilder
    private var signInMethods: some View {
        switch model.authConfigState {
        case .unknown:
            if !model.settings.isConfigured {
                Text("Save a server address first.")
                    .foregroundStyle(Palette.secondary)
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Asking the server how to sign in")
                    .foregroundStyle(Palette.secondary)
            }
        case .failed:
            Text("The server could not be asked how to sign in. Check the address and the VPN.")
                .font(.footnote)
                .foregroundStyle(Palette.amber)
            Button("Ask again") {
                Task { await model.refreshServerFacts() }
            }
        case .loaded(let config):
            methodRows(config)
        }
    }

    @ViewBuilder
    private func methodRows(_ config: AuthConfig) -> some View {
        if config.supportsOIDC {
            Button {
                Task { await model.signInWithHelmholtz() }
            } label: {
                HStack(spacing: 8) {
                    Text("Sign in with Helmholtz AAI")
                    if model.isSigningIn {
                        Spacer(minLength: 8)
                        ProgressView()
                    }
                }
            }
            .disabled(model.isSigningIn)
        }
        if config.supportsToken {
            SecureField("Access token", text: $token)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save token") {
                saveToken()
            }
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSigningIn)
        }
        if !config.supportsOIDC && !config.supportsToken {
            Text("The server offers no sign-in method this app knows.")
                .font(.footnote)
                .foregroundStyle(Palette.amber)
        }
    }

    @ViewBuilder
    private var signInFooter: some View {
        if case .loaded(let config) = model.authConfigState, config.supportsToken {
            Text("A server running in demo mode accepts the token demo. The token is kept in the keychain and shared with the widgets.")
        } else {
            Text("The sign-in is kept in the keychain and shared with the widgets.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("App version", value: SettingsText.appVersion)
            LabeledContent("Server version", value: model.serverHealth?.version ?? Format.dash)
            LabeledContent("Server schema version", value: serverSchemaText)
            LabeledContent("App schema version", value: "\(SlurmKitConstants.schemaVersion)")
            if schemaMismatch {
                Text("The server uses a different schema version from the one this app was written for. Some figures may be missing or wrong.")
                    .font(.footnote)
                    .foregroundStyle(Palette.amber)
            }
        } header: {
            Text("About")
        }
        .listRowBackground(Palette.panel)
    }

    private var serverSchemaText: String {
        guard let health = model.serverHealth else { return Format.dash }
        return "\(health.schemaVersion)"
    }

    private var schemaMismatch: Bool {
        guard let health = model.serverHealth else { return false }
        return health.schemaVersion != SlurmKitConstants.schemaVersion
    }

    // MARK: Draft and validation

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedAddress: URL? {
        ServerSettings.parseServerURL(address)
    }

    /// A sentence when the typed address cannot be used; nil when it can or is empty.
    private var addressProblem: String? {
        if trimmedAddress.isEmpty {
            return nil
        }
        guard let url = parsedAddress else {
            return "This is not a usable address."
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "https" && scheme != "http" {
            return "The address must begin with https:// or http://."
        }
        return nil
    }

    private var addressAdvice: String? {
        guard let url = parsedAddress, url.scheme?.lowercased() == "http" else {
            return nil
        }
        return "This address is not encrypted, and iOS may refuse the connection. Use https where the server offers it."
    }

    private var draft: ServerSettings {
        ServerSettings(
            serverURL: parsedAddress,
            username: SettingsText.nonEmpty(username),
            defaultPartition: SettingsText.nonEmpty(partition)
        )
    }

    private var canSave: Bool {
        addressProblem == nil && draft != model.settings
    }

    // MARK: Actions

    private func fillFieldsOnce() {
        guard !didFillFields else { return }
        didFillFields = true
        fillFields(from: model.settings)
    }

    private func fillFields(from settings: ServerSettings) {
        address = settings.serverURL?.absoluteString ?? ""
        username = settings.username ?? ""
        partition = settings.defaultPartition ?? ""
    }

    private func save() {
        guard canSave else { return }
        model.applySettings(draft)
        Task {
            await model.refreshServerFacts()
        }
    }

    private func runConnectionTest() {
        guard let url = parsedAddress else { return }
        connectionTest = .running
        Task {
            let result = await model.testConnection(to: url)
            if parsedAddress == url {
                connectionTest = result
            }
        }
    }

    private func saveToken() {
        let entered = token
        token = ""
        Task {
            await model.saveStaticToken(entered)
        }
    }
}

/// The sentences of the Settings section.
enum SettingsText {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? Format.dash
        if let build = info["CFBundleVersion"] as? String {
            return "\(version) (\(build))"
        }
        return version
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func lastPoll(_ health: HealthStatus) -> String {
        guard let date = health.lastPollAt else {
            return "The server has not polled Slurm yet."
        }
        let time = Format.clockTime(date, timeZone: .current)
        if health.lastPollOk == false {
            return "Last poll at \(time) failed; the server answers from an older one."
        }
        return "Last poll at \(time)."
    }

    static func status(_ status: SignInStatus) -> String {
        switch status {
        case .unknown:
            return "Not checked"
        case .checking:
            return "Checking"
        case .signedOut:
            return "Not signed in"
        case .signedIn(let identity):
            let method = identity.method == "oidc" ? "Helmholtz AAI" : "a token"
            if let username = identity.username, !username.isEmpty {
                return "Signed in with \(method) as \(username)"
            }
            return "Signed in with \(method)"
        case .refused:
            return "The server refused the stored sign-in"
        case .unverified(let oidc):
            let kind = oidc ? "A Helmholtz AAI sign-in" : "A token"
            return "\(kind) is stored; the server could not be asked about it"
        }
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsScreen()
    }
    .environmentObject(AppModel(
        settings: ServerSettings(),
        credentialStore: InMemoryCredentialStore()
    ))
    .preferredColorScheme(.dark)
}
