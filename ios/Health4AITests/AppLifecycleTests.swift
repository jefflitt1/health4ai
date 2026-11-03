import SwiftUI
import UIKit
import XCTest
@testable import Health4AI

// The app is scene-based (UIApplicationSceneManifest), so UIKit never calls the app delegate's
// lifecycle callbacks; a simulator probe on 2026-11-02 logged scenePhase changes and zero
// app-delegate callbacks. Foreground and background work therefore runs from scenePhase only.

@MainActor
final class AppLifecycleTests: XCTestCase {
    private final class Calls { var active = 0; var background = 0 }

    private func lifecycle(_ calls: Calls) -> AppLifecycle {
        AppLifecycle(becameActive: { calls.active += 1 }, enteredBackground: { calls.background += 1 })
    }

    /// The first activation (cold launch) runs the foreground work once.
    func testFirstActivationRunsForegroundWork() {
        let calls = Calls()
        let l = lifecycle(calls)
        l.handle(.inactive)
        l.handle(.active)
        XCTAssertEqual(calls.active, 1)
        XCTAssertEqual(calls.background, 0)
    }

    /// A full background-and-return cycle runs each piece of work exactly once more.
    func testBackgroundAndReturnRunsEachOnce() {
        let calls = Calls()
        let l = lifecycle(calls)
        for phase in [ScenePhase.active, .inactive, .background, .inactive, .active] { l.handle(phase) }
        XCTAssertEqual(calls.active, 2)
        XCTAssertEqual(calls.background, 1)
    }

    /// Control Center, the notification shade or a system alert go active -> inactive -> active
    /// without backgrounding. None of those may start another sync pass.
    func testInactiveBlipDoesNoWork() {
        let calls = Calls()
        let l = lifecycle(calls)
        for phase in [ScenePhase.active, .inactive, .active, .inactive, .active] { l.handle(phase) }
        XCTAssertEqual(calls.active, 1)
        XCTAssertEqual(calls.background, 0)
    }

    /// The live router reaches the app delegate's real scene work (the wiring, not a stub).
    func testLiveRouterRunsTheRealSceneWork() {
        AppDelegate.recordedSceneWork = []
        defer { AppDelegate.recordedSceneWork = [] }
        let live = AppLifecycle.makeLive()
        for phase in [ScenePhase.active, .inactive, .active, .inactive, .background, .inactive, .active] {
            live.handle(phase)
        }
        XCTAssertEqual(AppDelegate.recordedSceneWork, ["active", "background", "active"])
    }

    /// The app delegate must not implement the lifecycle callbacks UIKit never delivers to a
    /// scene-based app; work placed there silently never runs (the bug this file guards).
    func testAppDelegateDoesNotImplementUndeliveredCallbacks() {
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.responds(to: #selector(UIApplicationDelegate.applicationDidBecomeActive(_:))))
        XCTAssertFalse(delegate.responds(to: #selector(UIApplicationDelegate.applicationDidEnterBackground(_:))))
        XCTAssertFalse(delegate.responds(to: #selector(UIApplicationDelegate.applicationWillEnterForeground(_:))))
    }
}
