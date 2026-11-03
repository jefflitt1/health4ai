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

    /// Becoming active runs the foreground work once and nothing else.
    func testActiveRunsForegroundWork() {
        let calls = Calls()
        lifecycle(calls).handle(.active)
        XCTAssertEqual(calls.active, 1)
        XCTAssertEqual(calls.background, 0)
    }

    /// Entering the background runs the background work once and nothing else.
    func testBackgroundRunsBackgroundWork() {
        let calls = Calls()
        lifecycle(calls).handle(.background)
        XCTAssertEqual(calls.active, 0)
        XCTAssertEqual(calls.background, 1)
    }

    /// The brief inactive step between foreground and background does no work.
    func testInactiveDoesNothing() {
        let calls = Calls()
        lifecycle(calls).handle(.inactive)
        XCTAssertEqual(calls.active, 0)
        XCTAssertEqual(calls.background, 0)
    }

    /// A full background-and-return cycle runs each piece of work exactly once.
    func testRoundTripRunsEachOnce() {
        let calls = Calls()
        let l = lifecycle(calls)
        for phase in [ScenePhase.inactive, .background, .inactive, .active] { l.handle(phase) }
        XCTAssertEqual(calls.active, 1)
        XCTAssertEqual(calls.background, 1)
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
