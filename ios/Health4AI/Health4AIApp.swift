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
///
/// Foreground work runs on the first activation and after a real trip to the background only.
/// Control Center, the notification shade, system alerts and the Face ID sheet go
/// active -> inactive -> active without backgrounding; each of those would otherwise start a
/// full sync pass and a HealthKit access check.
@MainActor
final class AppLifecycle {
    private let becameActive: () -> Void
    private let enteredBackground: () -> Void
    private var foregroundWorkOwed = true

    init(becameActive: @escaping () -> Void, enteredBackground: @escaping () -> Void) {
        self.becameActive = becameActive
        self.enteredBackground = enteredBackground
    }

    func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard foregroundWorkOwed else { return }
            foregroundWorkOwed = false
            becameActive()
        case .background:
            foregroundWorkOwed = true
            enteredBackground()
        default:
            break
        }
    }

    /// A router wired to the app's real foreground and background work.
    static func makeLive() -> AppLifecycle {
        AppLifecycle(
            becameActive: {
                AppDelegate.sceneBecameActive()
                // A no-op while the bike feature is off.
                Task { @MainActor in await BikeImportCoordinator.shared.importOnForeground() }
            },
            enteredBackground: { AppDelegate.sceneEnteredBackground() }
        )
    }

    static let live = makeLive()
}
