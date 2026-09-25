import SwiftUI
import HealthKit
import Security

// MARK: - Root view

// MARK: - TabRouter

/// Lets a view outside `MainTabView` (Home's "Connect your database" button) switch tabs
/// without owning the `TabView`'s own selection state. A single shared instance, injected
/// alongside `syncState`/`authManager`.
final class TabRouter: ObservableObject {
    @Published var selectedTab: Int = 0
}

struct ContentView: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var tabRouter = TabRouter()
    @AppStorage("hkb.onboardingComplete") private var onboardingComplete = false

    var body: some View {
        Group {
            #if DEBUG
            // Design-gate screenshots only: jumps straight past onboarding and, for the new
            // screens added in 1.0.1, straight past their own tab too, since a simulator
            // screenshot run has no UI-automation harness to tap through to them. Same
            // DEBUG + launch-argument gating as every other `-h4aiScreenshot…` fixture in
            // this app; none of this compiles into Release.
            if let screen = Self.debugDirectScreen() {
                NavigationStack { screen }
            } else if onboardingComplete || Self.isScreenshotRun {
                MainTabView()
            } else {
                OnboardingView()
            }
            #else
            if onboardingComplete {
                MainTabView()
            } else {
                OnboardingView()
            }
            #endif
        }
        .environmentObject(syncState)
        .environmentObject(authManager)
        .environmentObject(tabRouter)
    }

    #if DEBUG
    private static var isScreenshotRun: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-h4aiScreenshot") }
    }

    @MainActor
    private static func debugDirectScreen() -> AnyView? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-h4aiScreenshotSyncHistory") { return AnyView(SyncHistoryView()) }
        if args.contains("-h4aiScreenshotSources") { return AnyView(SourcesView()) }
        if args.contains("-h4aiScreenshotConnectAI") { return AnyView(ConnectAIView()) }
        if args.contains("-h4aiScreenshotSetupChecklist") { return AnyView(ConnectionView()) }
        return nil
    }
    #endif
}

// MARK: - Tab container

struct MainTabView: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var tabRouter: TabRouter

    var body: some View {
        TabView(selection: $tabRouter.selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "waveform.path.ecg")
                }
                .environmentObject(syncState)
                .environmentObject(tabRouter)
                .tag(0)

            ConnectionView()
                .tabItem {
                    Label("Connect", systemImage: "server.rack")
                }
                .environmentObject(syncState)
                .environmentObject(authManager)
                .tag(1)

            PrivacyView()
                .tabItem {
                    Label("Privacy", systemImage: "lock.shield")
                }
                .tag(2)
        }
    }
}

// MARK: - CredentialKeychain

/// Keychain storage for sensitive credential strings (anon key, bearer token, API key).
/// Uses the same kSecClassGenericPassword pattern as AuthManager.
enum CredentialKeychain {
    static let service = "com.healthkitbridge.credentials"

    static let sensitiveKeys: Set<String> = [
        "hkb.supabaseAnonKey",
        "hkb.restBearerToken",
        "hkb.restApiKeyValue",
    ]

    static func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: key as CFString,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        if !value.isEmpty {
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service as CFString,
                kSecAttrAccount: key as CFString,
                kSecValueData: data as CFData,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func load(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: key as CFString,
            kSecReturnData: kCFBooleanTrue!,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAll() {
        for key in sensitiveKeys {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service as CFString,
                kSecAttrAccount: key as CFString,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

// MARK: - SecureFieldToggle (shared across views)

/// Togglable secure/plain text field.
/// Keys in `CredentialKeychain.sensitiveKeys` persist to iOS Keychain; others to UserDefaults.
struct SecureFieldToggle: View {
    let placeholder: String
    let userDefaultsKey: String
    /// Called after every persisted change, in addition to the Keychain/UserDefaults write
    /// below — so a caller that needs to know "is this field non-empty right now" (the
    /// Connect setup checklist) can hold that in its own @State instead of re-reading
    /// Keychain from an unobserved computed property, which SwiftUI never re-evaluates.
    var onValueChange: ((String) -> Void)? = nil

    @State private var value: String
    @State private var isVisible = false

    private var isSensitive: Bool { CredentialKeychain.sensitiveKeys.contains(userDefaultsKey) }

    init(placeholder: String, userDefaultsKey: String, onValueChange: ((String) -> Void)? = nil) {
        self.placeholder = placeholder
        self.userDefaultsKey = userDefaultsKey
        self.onValueChange = onValueChange
        let sensitive = CredentialKeychain.sensitiveKeys.contains(userDefaultsKey)
        _value = State(initialValue: sensitive
            ? CredentialKeychain.load(forKey: userDefaultsKey) ?? ""
            : UserDefaults.standard.string(forKey: userDefaultsKey) ?? "")
    }

    var body: some View {
        HStack {
            Group {
                if isVisible {
                    TextField(placeholder, text: $value)
                } else {
                    SecureField(placeholder, text: $value)
                }
            }
            .autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
            .font(.system(.caption, design: .monospaced))
            .onChange(of: value) { _, newValue in
                if isSensitive {
                    CredentialKeychain.save(newValue, forKey: userDefaultsKey)
                } else {
                    UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
                }
                onValueChange?(newValue)
            }
            .onAppear { onValueChange?(value) }
            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            // Without this VoiceOver reads the raw symbol name — "eye" — which says
            // nothing about what the control does or what it is guarding.
            .accessibilityLabel(isVisible ? "Hide value" : "Show value")
        }
    }
}

// MARK: - SignInView (Supabase)

struct SignInView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var syncState: SyncState
    @Environment(\.dismiss) var dismiss

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSigningIn = false
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Supabase Account") {
                    Text("Sign in with an account in your own Supabase project. health4ai does not create or operate this account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Email", text: $email)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        signIn()
                    } label: {
                        Group {
                            if isSigningIn {
                                HStack {
                                    ProgressView().scaleEffect(0.8)
                                    Text("Signing In…")
                                }
                            } else {
                                Text("Sign In")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(email.isEmpty || password.isEmpty || isSigningIn)
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func signIn() {
        isSigningIn = true
        error = nil
        Task {
            do {
                let response = try await authManager.signIn(
                    email: email,
                    password: password,
                    serverURL: syncState.resolvedEndpointURL
                )
                await MainActor.run {
                    syncState.isAuthenticated = true
                    syncState.userEmail = response.user.email
                    // Not a secret (a Supabase Auth user id), and the only place ConnectAIView
                    // can get it to prefill HEALTHKIT_USER_ID without asking the user to dig
                    // it out of the Supabase dashboard themselves.
                    UserDefaults.standard.set(response.user.id, forKey: "hkb.healthkitUserID")
                    isSigningIn = false
                }
                try? await HealthKitManager.shared.requestAuthorization()
                SyncEngine.shared.startObserving()
                if BulkExportManager.shared.backfillNeeded {
                    BulkExportManager.shared.startBackfill(syncState: syncState)
                } else {
                    SyncEngine.shared.performForegroundSync()
                }
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    isSigningIn = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SyncState())
        .environmentObject(AuthManager())
}
