import SwiftUI

// UI for the Google Sheets destination: the destination choice on the Connection tab, the
// Sheets connect/disconnect section, and the Home status card.

enum SheetsFeature {
    /// TestFlight and debug builds only until the 1.1 release, so `main` stays shippable to
    /// the App Store with the feature dark (plan step 7). The sandbox receipt is how a
    /// TestFlight install identifies itself.
    static let isAvailable: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()
}

// MARK: - Destination picker

struct DestinationPickerSection: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager
    @State private var pending: ConnectionType?

    var body: some View {
        Section {
            Picker("Destination", selection: Binding(
                get: { syncState.connectionType == .googleSheets ? ConnectionType.googleSheets : .supabase },
                set: { choose($0) }
            )) {
                Text("Google Sheet").tag(ConnectionType.googleSheets)
                Text("Your database").tag(ConnectionType.supabase)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Where your data goes")
        } footer: {
            Text(syncState.connectionType == .googleSheets
                 ? "Easiest. A spreadsheet in your own Google Drive with one row per day. Any AI that can read Google Drive can use it."
                 : "For technical users. Every reading, into a Postgres database you run.")
        }
        .confirmationDialog("Switch destination?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button("Switch", role: .destructive) {
                if let pending { switchTo(pending) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("health4ai sends data to one place at a time. Switching disconnects the current one. Nothing already saved there is deleted.")
        }
    }

    private func choose(_ type: ConnectionType) {
        guard type != syncState.connectionType else { return }
        if syncState.isAuthenticated {
            pending = type
        } else {
            syncState.connectionType = type
        }
    }

    private func switchTo(_ type: ConnectionType) {
        SyncEngine.shared.stopObserving()
        if syncState.connectionType == .googleSheets {
            Task { await GoogleTokenStore.shared.signOut() }
            SheetsDestinationState.clear()
        } else {
            authManager.signOut()
        }
        syncState.isAuthenticated = false
        syncState.userEmail = nil
        syncState.sheetsNeedsAttention = nil
        syncState.connectionType = type
    }
}

// MARK: - Connect section (Connection tab, Sheets mode)

struct SheetsConnectSection: View {
    @EnvironmentObject var syncState: SyncState
    @State private var working = false
    @State private var errorText: String?
    @State private var showDisconnect = false
    @State private var coordinator = GoogleSignInCoordinator()

    private var sheetURL: URL? { SheetsDestinationState.load().flatMap { URL(string: $0.spreadsheetURL) } }

    var body: some View {
        Section {
            if syncState.isAuthenticated && syncState.sheetsNeedsAttention == nil {
                Label("Connected to Google", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let sheetURL {
                    Link(destination: sheetURL) {
                        Label("Open my sheet", systemImage: "tablecells")
                    }
                } else {
                    Text("Your sheet is being created. It appears here after the first sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Disconnect Google", role: .destructive) { showDisconnect = true }
            } else {
                if let attention = syncState.sheetsNeedsAttention {
                    Label(attention, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button {
                    connect()
                } label: {
                    HStack {
                        Label(syncState.sheetsNeedsAttention == nil ? "Connect Google" : "Reconnect Google",
                              systemImage: "person.crop.circle.badge.checkmark")
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(working)
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Google Sheet")
        } footer: {
            Text("health4ai creates one spreadsheet named \"health4ai\" in your Google Drive and can only see that file. Your health data goes straight from this iPhone to your Drive. health4ai never receives it.")
        }
        .alert("Disconnect Google?", isPresented: $showDisconnect) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your sheet stays in your Google Drive but stops updating. Connecting again starts a new sheet.")
        }

        Section {
            Text("In ChatGPT, Claude or Gemini, connect Google Drive, then ask things like \"Using my health4ai sheet, how has my sleep changed this month?\"")
                .font(.callout)
        } header: {
            Text("Ask your AI")
        }
    }

    private func connect() {
        working = true
        errorText = nil
        Task { @MainActor in
            defer { working = false }
            do {
                try await HealthKitManager.shared.requestAuthorization()
                try await coordinator.signIn()
                // A reconnect after "sheet deleted" or "access removed" starts clean.
                if syncState.sheetsNeedsAttention != nil { SheetsDestinationState.clear() }
                syncState.sheetsNeedsAttention = nil
                syncState.connectionType = .googleSheets
                syncState.isAuthenticated = true
                SyncEngine.shared.startObserving()
                SyncEngine.shared.performForegroundSync(trigger: .manual)
            } catch GoogleAuthError.cancelled {
                // The person closed the sheet; nothing to report.
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        SyncEngine.shared.stopObserving()
        Task { await GoogleTokenStore.shared.signOut() }
        SheetsDestinationState.clear()
        syncState.isAuthenticated = false
        syncState.sheetsNeedsAttention = nil
        syncState.lastSyncDate = nil
    }
}

// MARK: - Home card (Sheets mode)

struct SheetsHomeCard: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var tabRouter: TabRouter

    private var state: SheetsDestinationState? { SheetsDestinationState.load() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Google Sheet", systemImage: "tablecells")
                .font(.headline)
            if let attention = syncState.sheetsNeedsAttention {
                Label(attention, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                Button("Fix on the Connection tab") { tabRouter.selectedTab = 1 }  // Connection tab, as HomeView.swift does
                    .buttonStyle(.borderedProminent)
            } else if let state, let url = URL(string: state.spreadsheetURL) {
                if let day = state.lastWrittenDay {
                    Text("Up to date through \(day).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Link(destination: url) {
                    Label("Open my sheet", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Creating your sheet…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
