import SwiftUI

// MARK: - ConnectionView (Settings tab)

struct ConnectionView: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager

    @State private var showSignIn = false
    @State private var showSignOut = false
    @State private var testResult: TestResult? = nil
    @State private var isTesting = false
    var body: some View {
        NavigationStack {
            List {
                backendTypeSection
                configSection
                authSection
                testSection
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
                .environmentObject(authManager)
                .environmentObject(syncState)
        }
        .alert("Sign Out", isPresented: $showSignOut) {
            Button("Sign Out", role: .destructive) {
                authManager.signOut()
                SyncEngine.shared.stopObserving()
                Task { @MainActor in
                    syncState.isAuthenticated = false
                    syncState.userEmail = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to sign in again to resume syncing.")
        }
    }

    // MARK: - Backend type

    private var backendTypeSection: some View {
        Section {
            Picker("Backend", selection: $syncState.connectionType) {
                ForEach(ConnectionType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Backend Type")
        } footer: {
            switch syncState.connectionType {
            case .supabase:
                Text("Enter your Supabase project URL and anon key. The sync endpoint is configured automatically.")
            case .rest:
                Text("Enter any HTTPS endpoint that accepts JSON POST requests.")
            }
        }
    }

    // MARK: - Config (conditional on type)

    @ViewBuilder
    private var configSection: some View {
        switch syncState.connectionType {
        case .supabase:
            supabaseConfigSection
        case .rest:
            restConfigSection
        }
    }

    private var supabaseConfigSection: some View {
        Section {
            LabeledContent("Project URL") {
                TextField("https://abc123.supabase.co", text: $syncState.supabaseProjectURL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.caption, design: .monospaced))
            }
            LabeledContent("Anon Key") {
                SecureFieldToggle(placeholder: "eyJ…", userDefaultsKey: "hkb.supabaseAnonKey")
            }
        } header: {
            Text("Supabase")
        } footer: {
            if !syncState.supabaseProjectURL.isEmpty {
                Text("Endpoint: \(syncState.resolvedEndpointURL)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var restConfigSection: some View {
        Section {
            LabeledContent("Endpoint URL") {
                TextField("https://your-server.com/api/health", text: $syncState.serverURL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.caption, design: .monospaced))
            }
            Picker("Auth", selection: $syncState.restAuthType) {
                ForEach(RestAuthType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            switch syncState.restAuthType {
            case .none:
                EmptyView()
            case .bearer:
                LabeledContent("Bearer Token") {
                    SecureFieldToggle(placeholder: "Token", userDefaultsKey: "hkb.restBearerToken")
                }
            case .apiKey:
                LabeledContent("Header Name") {
                    TextField("X-API-Key", text: $syncState.restApiKeyHeader)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Key Value") {
                    SecureFieldToggle(placeholder: "your-key", userDefaultsKey: "hkb.restApiKeyValue")
                }
            }
        } header: {
            Text("REST Endpoint")
        }
    }

    // MARK: - Auth (Supabase only)

    @ViewBuilder
    private var authSection: some View {
        if syncState.connectionType == .supabase {
            Section {
                if syncState.isAuthenticated {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text("Signed In")
                                .fontWeight(.medium)
                            if let email = syncState.userEmail {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Sign Out") { showSignOut = true }
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        showSignIn = true
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.plus")
                            Text("Sign In to Supabase")
                                .fontWeight(.medium)
                        }
                    }
                }
            } header: {
                Text("Authentication")
            }
        }
    }

    // MARK: - Test connection

    private var testSection: some View {
        Section {
            Button {
                testConnection()
            } label: {
                HStack {
                    if isTesting {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "network")
                    }
                    Text(isTesting ? "Testing…" : "Test Connection")
                }
            }
            .disabled(isTesting)

            if let result = testResult {
                Label(result.message, systemImage: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(result.success ? .green : .red)
            }
        } header: {
            Text("Verify")
        } footer: {
            Text("Sends a small ping to your endpoint to confirm it's reachable.")
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let url = syncState.resolvedEndpointURL
        guard let endpoint = URL(string: url) else {
            testResult = TestResult(success: false, message: "Invalid URL")
            isTesting = false
            return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ping": true])
        req.timeoutInterval = 10

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ok = (200...299).contains(code) || code == 401 || code == 403
                await MainActor.run {
                    testResult = TestResult(success: ok, message: ok ? "Endpoint reachable (HTTP \(code))" : "HTTP \(code) — check your config")
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = TestResult(success: false, message: error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }
}

private struct TestResult {
    let success: Bool
    let message: String
}

// MARK: - Shared picker (used in onboarding too)

struct ConnectionPickerView: View {
    @EnvironmentObject var syncState: SyncState

    var body: some View {
        Form {
            Section {
                Picker("Backend", selection: $syncState.connectionType) {
                    ForEach(ConnectionType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(syncState.connectionType == .supabase
                     ? "Supabase is recommended if you want AI agents to query your data via MCP."
                     : "Any HTTPS endpoint that accepts JSON POST requests.")
            }
            if syncState.connectionType == .supabase {
                Section("Supabase") {
                    TextField("Project URL (https://…)", text: $syncState.supabaseProjectURL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureFieldToggle(placeholder: "Anon Key (eyJ…)", userDefaultsKey: "hkb.supabaseAnonKey")
                }
            } else {
                Section("REST Endpoint") {
                    TextField("https://your-server.com/api/health", text: $syncState.serverURL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Picker("Auth", selection: $syncState.restAuthType) {
                        ForEach(RestAuthType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    if syncState.restAuthType == .bearer {
                        SecureFieldToggle(placeholder: "Bearer token", userDefaultsKey: "hkb.restBearerToken")
                    }
                }
            }
        }
    }
}
