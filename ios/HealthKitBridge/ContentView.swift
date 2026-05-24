import SwiftUI
import HealthKit

// MARK: - ContentView (Settings Screen)

struct ContentView: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager

    @State private var showSignIn = false
    @State private var showSignOut = false
    @State private var isRequestingHK = false
    @State private var hkAuthError: String? = nil
    @State private var editingServerURL = false
    @State private var pendingServerURL: String = ""

    var body: some View {
        NavigationStack {
            List {
                serverSection
                authSection
                syncStatusSection
                syncActionsSection
                backfillSection
            }
            .navigationTitle("HealthKit Bridge")
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

    // MARK: - Server section

    private var serverSection: some View {
        Section {
            if editingServerURL {
                HStack {
                    TextField("Server URL", text: $pendingServerURL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Save") {
                        syncState.serverURL = pendingServerURL.trimmingCharacters(in: .whitespaces)
                        editingServerURL = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Endpoint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(syncState.serverURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    pendingServerURL = syncState.serverURL
                    editingServerURL = true
                }
            }

            supabaseAnonKeyField
        } header: {
            Text("Configuration")
        } footer: {
            Text("Tap the endpoint URL to edit. The anon key is required for sign-in.")
        }
    }

    private var supabaseAnonKeyField: some View {
        HStack {
            Text("Supabase Anon Key")
                .foregroundStyle(.secondary)
            Spacer()
            SecureFieldToggle(
                placeholder: "eyJ...",
                userDefaultsKey: "hkb.supabaseAnonKey"
            )
        }
    }

    // MARK: - Auth section

    private var authSection: some View {
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
                    Button("Sign Out") {
                        showSignOut = true
                    }
                    .foregroundStyle(.red)
                }
            } else {
                Button {
                    showSignIn = true
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.plus")
                        Text("Sign In")
                            .fontWeight(.medium)
                    }
                }

                if let error = hkAuthError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            healthKitPermissionRow
        } header: {
            Text("Authentication")
        }
    }

    private var healthKitPermissionRow: some View {
        Button {
            requestHealthKitPermissions()
        } label: {
            HStack {
                if isRequestingHK {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                }
                Text("Request HealthKit Access")
            }
        }
        .disabled(isRequestingHK)
    }

    // MARK: - Sync status section

    private var syncStatusSection: some View {
        Section {
            LabeledContent("Status") {
                if syncState.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Syncing…")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = syncState.syncError {
                    Label(error, systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Idle")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Last Sync") {
                Text(syncState.formattedLastSync)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Records (last sync)") {
                Text("\(syncState.lastSyncRecordCount)")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Total Records Synced") {
                Text("\(syncState.lifetimeSyncedRecords)")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Next Scheduled") {
                Text(syncState.formattedNextSync)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Sync Status")
        }
    }

    // MARK: - Sync actions

    private var syncActionsSection: some View {
        Section {
            Button {
                SyncEngine.shared.performForegroundSync()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Sync Now")
                }
            }
            .disabled(syncState.isSyncing || !syncState.isAuthenticated)
        } header: {
            Text("Actions")
        }
    }

    // MARK: - Backfill section

    private var backfillSection: some View {
        Section {
            if syncState.backfillCompleted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Backfill Complete")
                    Spacer()
                    Text("\(syncState.lifetimeSyncedRecords) total records")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if syncState.isBackfilling {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Backfilling historical data…")
                            .font(.subheadline)
                    }
                    ProgressView(value: syncState.backfillProgressFraction)
                        .progressViewStyle(.linear)
                    Text("\(syncState.backfillSyncedRecords) records synced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let earliest = syncState.backfillEarliestDate {
                        Text("From: \(earliest.formatted(.dateTime.month().year()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") {
                        BulkExportManager.shared.cancelBackfill()
                    }
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }

            if let error = syncState.backfillError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !syncState.isBackfilling {
                Button {
                    startBackfill()
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(syncState.backfillCompleted ? "Re-run Backfill" : "Run Backfill")
                    }
                }
                .disabled(!syncState.isAuthenticated)
            }
        } header: {
            Text("Historical Backfill")
        } footer: {
            Text("Backfill queries all historical HealthKit data and uploads it in batches of 500. This may take several minutes.")
        }
    }

    // MARK: - Actions

    private func requestHealthKitPermissions() {
        isRequestingHK = true
        hkAuthError = nil
        Task {
            do {
                try await HealthKitManager.shared.requestAuthorization()
                await MainActor.run { isRequestingHK = false }
            } catch {
                await MainActor.run {
                    isRequestingHK = false
                    hkAuthError = error.localizedDescription
                }
            }
        }
    }

    private func startBackfill() {
        if syncState.backfillCompleted {
            BulkExportManager.shared.resetBackfill()
            Task { @MainActor in
                syncState.backfillCompleted = false
                syncState.backfillSyncedRecords = 0
            }
        }
        BulkExportManager.shared.startBackfill(syncState: syncState)
    }
}

// MARK: - SecureFieldToggle

/// A secure text field that can be toggled to visible, backed by UserDefaults.
struct SecureFieldToggle: View {
    let placeholder: String
    let userDefaultsKey: String

    @State private var value: String
    @State private var isVisible = false

    init(placeholder: String, userDefaultsKey: String) {
        self.placeholder = placeholder
        self.userDefaultsKey = userDefaultsKey
        _value = State(initialValue: UserDefaults.standard.string(forKey: userDefaultsKey) ?? "")
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
            .autocapitalization(.none)
            .autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
            .font(.system(.caption, design: .monospaced))
            .onChange(of: value) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
            }

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - SignInView

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
                Section {
                    TextField("Email", text: $email)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Supabase Account")
                }

                if let error = error {
                    Section {
                        Label(error, systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        signIn()
                    } label: {
                        if isSigningIn {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Signing In…")
                            }
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .fontWeight(.semibold)
                        }
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
                    serverURL: syncState.serverURL
                )
                await MainActor.run {
                    syncState.isAuthenticated = true
                    syncState.userEmail = response.user.email
                    isSigningIn = false
                }

                // Kick off HealthKit permissions and sync after sign-in
                try? await HealthKitManager.shared.requestAuthorization()
                SyncEngine.shared.startObserving()

                // Run backfill if first time
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
