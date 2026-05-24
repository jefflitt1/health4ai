import UIKit
import BackgroundTasks
import HealthKit

// MARK: - AppDelegate

/// UIApplicationDelegate responsible for:
/// - BGTaskScheduler setup (must happen before applicationDidFinishLaunching returns)
/// - Foreground sync on launch and app-foreground transitions
/// - HealthKit observer startup after auth check
@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register BGTask handlers BEFORE the app finishes launching.
        // The system silently ignores registrations that happen after the app launch completes.
        SyncEngine.shared.registerBackgroundTasks()
        BulkExportManager.shared.registerBackgroundBackfillTask()

        // Check if we have a stored auth token and re-connect observers
        reconnectIfAuthenticated()

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Trigger foreground sync every time the app comes to the foreground
        if AuthManager().isSignedIn {
            SyncEngine.shared.performForegroundSync()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Schedule the next background sync task
        SyncEngine.shared.scheduleBackgroundSync()
        // Request ~30s grace time to finish the current backfill chunk, and schedule
        // a charging-only BGProcessingTask to run the backfill overnight
        BulkExportManager.shared.requestBackgroundTime()
        BulkExportManager.shared.scheduleBackgroundBackfill()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        BulkExportManager.shared.endBackgroundTime()
    }

    // MARK: - Private helpers

    private func reconnectIfAuthenticated() {
        let authManager = AuthManager()
        guard authManager.isSignedIn else { return }

        // Restore auth state to SyncState (shared singleton)
        let syncState = SyncEngine.sharedSyncState
        syncState.isAuthenticated = true
        syncState.userEmail = authManager.storedEmail

        // Re-register HealthKit observers so we don't miss data while the app was closed
        // requestAuthorization() must be user-initiated; calling it at launch causes
        // "Unable to acquire legacy assertion on com.apple.HealthPrivacyService".
        // startObserving() is a no-op when no permissions are granted; performForegroundSync()
        // fails gracefully per-type if the user hasn't authorized yet.
        guard HKHealthStore.isHealthDataAvailable() else { return }
        Task { @MainActor in
            SyncEngine.shared.startObserving()
            SyncEngine.shared.performForegroundSync()
            if BulkExportManager.shared.backfillNeeded {
                BulkExportManager.shared.startBackfill(syncState: syncState)
            }
        }
    }
}
