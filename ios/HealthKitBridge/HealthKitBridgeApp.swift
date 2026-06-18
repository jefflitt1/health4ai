import SwiftUI

// MARK: - HealthKitBridgeApp

@main
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
        .onChange(of: scenePhase) { newPhase in
            // BGTask scheduling disabled on iOS 27 Beta; AppDelegate handles lifecycle
            _ = newPhase
        }
    }
}
