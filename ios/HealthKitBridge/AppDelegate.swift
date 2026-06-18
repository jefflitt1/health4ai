import UIKit
import BackgroundTasks
import HealthKit

// MARK: - AppDelegate

/// UIApplicationDelegate responsible for:
/// - BGTaskScheduler setup (must happen before applicationDidFinishLaunching returns)
/// - Foreground sync on launch and app-foreground transitions
/// - HealthKit observer startup after auth check
///
/// NOT marked @MainActor — UIKit guarantees delegate callbacks are on the main thread,
/// but wrapping with @MainActor creates a Swift actor isolation layer that conflicts with
/// iOS 18's GCD/Mach port dispatch internals (triggers OS_dispatch_mach_msg _setContext: crash).
/// Use MainActor.assumeIsolated {} at call sites instead.
class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // UIKit guarantees main thread here — safe to assume main actor isolation
        MainActor.assumeIsolated {
            // Register BGTask handlers BEFORE the app finishes launching.
            // The system silently ignores registrations that happen after launch completes.
            SyncEngine.shared.registerBackgroundTasks()
            BulkExportManager.shared.registerBackgroundBackfillTask()

            // Check if we have a stored auth token and re-connect observers
            reconnectIfAuthenticated()
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        MainActor.assumeIsolated {
            let authManager = SyncEngine.sharedAuthManager
            if authManager.isSignedIn {
                SyncEngine.shared.performForegroundSync()
            }
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        MainActor.assumeIsolated {
            SyncEngine.shared.scheduleBackgroundSync()
            BulkExportManager.shared.requestBackgroundTime()
            BulkExportManager.shared.scheduleBackgroundBackfill()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        MainActor.assumeIsolated {
            BulkExportManager.shared.endBackgroundTime()
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func reconnectIfAuthenticated() {
        let authManager = SyncEngine.sharedAuthManager
        guard authManager.isSignedIn else { return }

        // Restore auth state to SyncState (shared singleton)
        let syncState = SyncEngine.sharedSyncState
        syncState.isAuthenticated = true
        syncState.userEmail = authManager.storedEmail

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
