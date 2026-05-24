import SwiftUI
import BackgroundTasks

// MARK: - HealthKitBridgeApp

@main
@MainActor
struct HealthKitBridgeApp: App {
    // UIApplicationDelegate adapter — required for BGTaskScheduler and lifecycle hooks
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Shared state objects injected into the SwiftUI environment
    // These reference the same singletons used by SyncEngine and BulkExportManager
    @StateObject private var syncState  = SyncEngine.sharedSyncState
    @StateObject private var authManager = SyncEngine.sharedAuthManager

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncState)
                .environmentObject(authManager)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Schedule background task when entering background via scene phase
                // (AppDelegate.applicationDidEnterBackground also fires, this is belt+suspenders)
                SyncEngine.shared.scheduleBackgroundSync()
            case .active:
                break // AppDelegate.applicationDidBecomeActive handles foreground sync
            default:
                break
            }
        }
    }
}
