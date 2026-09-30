import UIKit
import HealthKit

// MARK: - AppDelegate

/// UIApplicationDelegate responsible for:
/// - BGTaskScheduler registration (must happen before didFinishLaunching returns)
/// - Foreground sync on launch and app-foreground transitions
/// - HealthKit observer startup after auth check
/// - Scheduling the background sync and backfill tasks when the app leaves the foreground
class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register BGTask handlers BEFORE the app finishes launching. The system silently
        // ignores registrations made after launch completes, and a launch triggered by a
        // pending task would then find no handler. UIKit guarantees the main thread here.
        MainActor.assumeIsolated {
            SyncEngine.shared.registerBackgroundTasks()
            BulkExportManager.shared.registerBackgroundBackfillTask()
        }
        #if DEBUG
        // Screenshot fixtures for the Sync History and Your Sources screens. Launch-argument
        // gated, DEBUG-only — Xcode Cloud archives Release, which never compiles this branch.
        SyncHistoryStore.shared.seedForScreenshotsIfNeeded()
        SourcesTracker.shared.seedForScreenshotsIfNeeded()
        #if H4A_SHEETS
        MainActor.assumeIsolated { SheetsScreenshotFixture.applyIfRequested(SyncEngine.sharedSyncState) }
        #endif
        #endif
        Task { @MainActor in
            self.reconnectIfAuthenticated(trigger: .launch)
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { @MainActor in
            if Self.destinationConnected {
                SyncEngine.shared.performForegroundSync(trigger: .foreground)
            }
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Task { @MainActor in
            SyncEngine.shared.scheduleBackgroundSync()
            #if H4A_SHEETS
            // The history import uploads to the database; Sheets mode has its own sweep.
            guard !Self.isSheetsMode else { return }
            #endif
            BulkExportManager.shared.requestBackgroundTime()
            BulkExportManager.shared.scheduleBackgroundBackfill()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        Task { @MainActor in
            BulkExportManager.shared.endBackgroundTime()
        }
    }

    // MARK: - Private helpers

    #if H4A_SHEETS
    /// Sheets mode: the destination is the person's Google Sheet, not a database.
    @MainActor
    private static var isSheetsMode: Bool { SyncEngine.sharedSyncState.connectionType == .googleSheets }
    #endif

    /// Whether the chosen destination can receive data: a Google sign-in in Sheets mode,
    /// the Supabase session otherwise (unchanged for every existing install).
    @MainActor
    private static var destinationConnected: Bool {
        #if H4A_SHEETS
        if isSheetsMode { return GoogleTokenStore.shared.isSignedIn }
        #endif
        return SyncEngine.sharedAuthManager.isSignedIn
    }

    @MainActor
    private func reconnectIfAuthenticated(trigger: SyncTrigger) {
        #if H4A_SHEETS
        if Self.isSheetsMode {
            guard GoogleTokenStore.shared.isSignedIn, HKHealthStore.isHealthDataAvailable() else { return }
            SyncEngine.sharedSyncState.isAuthenticated = true
            SyncEngine.shared.startObserving()
            SyncEngine.shared.performForegroundSync(trigger: trigger)
            return
        }
        #endif
        let authManager = SyncEngine.sharedAuthManager
        guard authManager.isSignedIn else { return }

        let syncState = SyncEngine.sharedSyncState
        syncState.isAuthenticated = true
        syncState.userEmail = authManager.storedEmail

        guard HKHealthStore.isHealthDataAvailable() else { return }
        Task { @MainActor in
            SyncEngine.shared.startObserving()
            SyncEngine.shared.performForegroundSync(trigger: trigger)
            await BulkExportManager.shared.applyStuckTypeMigrationIfNeeded(syncState: syncState)
            await BulkExportManager.shared.applyMergedHoursResendIfNeeded(syncState: syncState)
            await BulkExportManager.shared.publishEmptyExpectedTypes(syncState: syncState)
            await BulkExportManager.shared.publishFailedImportTypes(syncState: syncState)
            if BulkExportManager.shared.backfillNeeded {
                BulkExportManager.shared.startBackfill(syncState: syncState)
            }
        }
    }
}
