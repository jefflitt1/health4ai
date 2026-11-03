import SwiftUI

// MARK: - Health4AIApp

@main
struct Health4AIApp: App {
    // UIApplicationDelegate adapter: BGTaskScheduler registration has to happen inside
    // didFinishLaunching, which SwiftUI's App protocol does not expose on its own.
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
        .onChange(of: scenePhase) { _, newPhase in AppLifecycle.live.handle(newPhase) }
    }
}

// MARK: - AppLifecycle

/// Routes SwiftUI scene-phase changes to the app's foreground and background work.
///
/// This is the only lifecycle path that fires: the app is scene-based, so UIKit never calls the
/// app delegate's applicationDidBecomeActive / applicationDidEnterBackground. The actions are
/// injectable so the routing is unit-tested.
@MainActor
struct AppLifecycle {
    var becameActive: () -> Void
    var enteredBackground: () -> Void

    func handle(_ phase: ScenePhase) {
        switch phase {
        case .active: becameActive()
        case .background: enteredBackground()
        default: break
        }
    }

    static let live = AppLifecycle(
        becameActive: {
            AppDelegate.sceneBecameActive()
            // A no-op while the bike feature is off.
            Task { @MainActor in await BikeImportCoordinator.shared.importOnForeground() }
        },
        enteredBackground: { AppDelegate.sceneEnteredBackground() }
    )
}
