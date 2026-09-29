import SwiftUI

// UI for the Google Sheets destination: the destination choice on the Connection tab, the
// Sheets connect/disconnect section, and the Home status card.
// Colour rule (design.md): colour goes on symbols only; text stays .primary/.secondary.

enum SheetsFeature {
    /// TestFlight and debug builds only until the 1.1 release. SyncState.init also coerces a
    /// stored Sheets choice back to the database when this is false, so the feature is dark
    /// in App Store builds, not just hidden (Reviewboard C). The sandbox receipt is how a
    /// TestFlight install identifies itself.
    static let isAvailable: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()
}

/// A status line with a coloured symbol and uncoloured text.
private struct StatusLine: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

// MARK: - Destination picker

struct DestinationPickerSection: View {
    @EnvironmentObject var syncState: SyncState
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pending: ConnectionType?

    private var selection: Binding<ConnectionType> {
        Binding(
            get: { syncState.connectionType == .googleSheets ? .googleSheets : .supabase },
            set: { choose($0) }
        )
    }

    var body: some View {
        Section {
            // Two segments truncate at accessibility text sizes on a 375pt screen; a menu
            // picker does not.
            if dynamicTypeSize.isAccessibilitySize {
                Picker("Destination", selection: selection) { options }
                    .pickerStyle(.menu)
                    .labelsHidden()
            } else {
                Picker("Destination", selection: selection) { options }
                    .pickerStyle(.segmented)
            }
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
            Text(syncState.connectionType == .googleSheets
                 ? "health4ai sends data to one place at a time. Your sheet stays in your Google Drive but stops updating. Coming back to Google Sheets later starts a new sheet."
                 : "health4ai sends data to one place at a time. Switching disconnects your database from this device. Nothing already saved there is deleted.")
        }
    }

    @ViewBuilder private var options: some View {
        Text("Google Sheet").tag(ConnectionType.googleSheets)
        Text("Your database").tag(ConnectionType.supabase)
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
            GoogleTokenStore.shared.signOut()
            SheetsDestinationState.clear()
        } else {
            authManager.signOut()
        }
        syncState.isAuthenticated = false
        syncState.userEmail = nil
        syncState.sheetsNeedsAttention = nil
        syncState.lastSyncDate = nil
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
            if let attention = syncState.sheetsNeedsAttention {
                StatusLine(text: attention.message, symbol: "exclamationmark.triangle.fill", tint: .orange)
                Button { resolve(attention) } label: { busyLabel(attention.actionTitle) }
                    .disabled(working)
            } else if syncState.isAuthenticated {
                StatusLine(text: "Connected to Google", symbol: "checkmark.circle.fill", tint: .green)
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
                Button { connect(keepSheet: false) } label: { busyLabel("Connect Google") }
                    .disabled(working)
            }
            if let errorText {
                StatusLine(text: errorText, symbol: "xmark.octagon.fill", tint: .red)
                    .font(.footnote)
            }
        } header: {
            Text("Google Sheet")
        } footer: {
            Text((syncState.isAuthenticated ? "" : "You'll be asked for Health access, then to sign in to Google. ")
                 + "health4ai creates one spreadsheet named \"health4ai\" in your Google Drive and can only see that file. Your health data goes straight from this device to your Drive and never passes through a health4ai server.")
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

    private func busyLabel(_ title: String) -> some View {
        HStack {
            Text(title)
            if working { Spacer(); ProgressView() }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(working ? "Connecting to Google" : title)
    }

    private func resolve(_ attention: SheetsAttention) {
        switch attention {
        case .reconnectGoogle:
            // Same sheet: drive.file access to a file the app created returns with sign-in.
            connect(keepSheet: true)
        case .sheetMissing:
            SheetsDestinationState.clear()
            syncState.sheetsNeedsAttention = nil
            SyncEngine.shared.performForegroundSync(trigger: .manual)
        case .healthAccess:
            syncState.sheetsNeedsAttention = nil
            SyncEngine.shared.performForegroundSync(trigger: .manual)
        }
    }

    private func connect(keepSheet: Bool) {
        working = true
        errorText = nil
        Task { @MainActor in
            defer { working = false }
            do {
                try await HealthKitManager.shared.requestAuthorization()
                try await coordinator.signIn()
                if !keepSheet { SheetsDestinationState.clear() }
                syncState.sheetsNeedsAttention = nil
                syncState.connectionType = .googleSheets
                syncState.isAuthenticated = true
                SyncEngine.shared.startObserving()
                SyncEngine.shared.performForegroundSync(trigger: .manual)
            } catch GoogleAuthError.cancelled {
                // The person closed the sign-in sheet; nothing to report.
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        SyncEngine.shared.stopObserving()
        GoogleTokenStore.shared.signOut()
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

    private func readable(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return key }
        return date.formatted(date: .long, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Google Sheet", systemImage: "tablecells")
                .font(.headline)
            if let attention = syncState.sheetsNeedsAttention {
                // The message itself lives here; the status card above only says
                // "Needs attention", so the words appear once (Sasha #2).
                StatusLine(text: attention.message, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .font(.subheadline)
                Button { tabRouter.selectedTab = 1 } label: {  // Connection tab, as HomeView does
                    Text(attention.actionTitle).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            } else if let state, let url = URL(string: state.spreadsheetURL) {
                if let day = state.lastWrittenDay {
                    Text(syncState.isSyncing ? "Filling in through \(readable(day))." : "Up to date through \(readable(day)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Link(destination: url) {
                    Label("Open my sheet", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity, minHeight: 44)
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

#if DEBUG
// MARK: - Screenshot fixture (DEBUG only)

/// Design-gate screenshots of the Sheets states. `-h4aiScreenshotSheets <state>` where state
/// is connected | attention | nohealth | missing | disconnected. Same DEBUG + launch-argument
/// gating as the app's other `-h4aiScreenshot…` fixtures; none of this compiles into Release.
/// There is no Google token in a simulator run, so no sync ever overwrites the fixture.
enum SheetsScreenshotFixture {
    @MainActor
    static func applyIfRequested(_ syncState: SyncState) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-h4aiScreenshotSheets"), i + 1 < args.count else { return }
        syncState.connectionType = .googleSheets
        let sheet = SheetsDestinationState(spreadsheetId: "fixture",
                                           spreadsheetURL: "https://docs.google.com/spreadsheets/d/fixture",
                                           units: SheetUnits(miles: true, pounds: true),
                                           lastWrittenDay: "2026-09-27")
        switch args[i + 1] {
        case "connected":
            sheet.save()
            syncState.isAuthenticated = true
            syncState.lastSyncDate = Date()
            syncState.lifetimeSyncedRecords = 3650
        case "attention":
            sheet.save()
            syncState.isAuthenticated = true
            syncState.sheetsNeedsAttention = .reconnectGoogle
        case "nohealth":
            SheetsDestinationState.clear()
            syncState.isAuthenticated = true
            syncState.sheetsNeedsAttention = .healthAccess
        case "missing":
            SheetsDestinationState.clear()
            syncState.isAuthenticated = true
            syncState.sheetsNeedsAttention = .sheetMissing
        default:
            SheetsDestinationState.clear()
            syncState.isAuthenticated = false
        }
    }
}
#endif
