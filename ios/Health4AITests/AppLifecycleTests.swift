import SwiftUI
import UIKit
import XCTest
@testable import Health4AI

final class SyncHistoryRetentionTests: XCTestCase {
    private func withStore(_ body: (SyncHistoryStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        try body(SyncHistoryStore(fileURL: url), url)
    }

    func testEmptyObserverBurstPreservesUsefulHistoryAndLatestCheckOnDisk() throws {
        try withStore { store, url in
            let upload = SyncHistoryEntry(date: Date(timeIntervalSince1970: 0),
                                          trigger: .foreground, counts: ["Heart Rate": 7], success: true)
            store.record(upload)
            var latest: SyncHistoryEntry!
            for second in 0..<100 {
                latest = SyncHistoryEntry(date: Date(timeIntervalSince1970: Double(second)),
                                          trigger: .backgroundDelivery, counts: [:], success: true)
                store.record(latest)
            }
            XCTAssertEqual(store.all(), [latest, upload])
            XCTAssertEqual(SyncHistoryStore(fileURL: url).all(), [latest, upload])
        }
    }

    func testFailuresAndUploadsSeparateEmptyObserverRuns() throws {
        try withStore { store, _ in
            let before = SyncHistoryEntry(trigger: .backgroundDelivery, counts: [:], success: true)
            let failure = SyncHistoryEntry(trigger: .backgroundDelivery, counts: [:], success: false,
                                           errorText: "Network failed")
            let upload = SyncHistoryEntry(trigger: .backgroundDelivery, counts: ["Steps": 2], success: true)
            let after = SyncHistoryEntry(trigger: .backgroundDelivery, counts: [:], success: true)
            for entry in [before, failure, upload, after] { store.record(entry) }
            XCTAssertEqual(store.all(), [after, upload, failure, before])
        }
    }

    func testEmptyForegroundAndScheduledPassesRemainSeparate() throws {
        try withStore { store, _ in
            let entries = [SyncTrigger.foreground, .foreground, .backgroundTask, .backgroundTask]
                .map { SyncHistoryEntry(trigger: $0, counts: [:], success: true) }
            entries.forEach { store.record($0) }
            XCTAssertEqual(store.all(), Array(entries.reversed()))
        }
    }

    func testMeaningfulEntriesStillRespectRetentionCap() throws {
        try withStore { store, url in
            let entries = (0..<60).map { second in
                SyncHistoryEntry(date: Date(timeIntervalSince1970: Double(second)),
                                 trigger: .backgroundDelivery, counts: ["Steps": 1], success: true)
            }
            entries.forEach { store.record($0) }
            let expected = Array(entries.reversed().prefix(SyncHistoryStore.cap))
            XCTAssertEqual(store.all(), expected)
            XCTAssertEqual(SyncHistoryStore(fileURL: url).all(), expected)
        }
    }
}

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
        AppDelegate.sceneWorkDryRun = true
        defer { AppDelegate.recordedSceneWork = []; AppDelegate.sceneWorkDryRun = false }
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

    func testLockedFullPassDoesNotClaimSuccessOrChangeAnchors() async {
        let state = SyncEngine.sharedSyncState
        let oldDeferred = state.deferredHealthWork
        let oldError = state.syncError
        let oldAuth = state.isAuthenticated
        state.isAuthenticated = true
        let lastSync = state.lastSyncDate
        let anchors = UserDefaults.standard.data(forKey: "hkb.syncAnchors")
        let count = state.lastSyncRecordCount
        ProtectedHealthData.availabilityOverride = false
        state.syncError = "Existing network error"
        defer {
            ProtectedHealthData.availabilityOverride = nil
            state.isAuthenticated = oldAuth
            state.deferredHealthWork = oldDeferred
            state.syncError = oldError
        }
        let outcome = await SyncEngine.shared.runFullPass(trigger: .launch)
        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(state.deferredHealthWork.contains(.sync))
        XCTAssertEqual(state.lastSyncDate, lastSync)
        XCTAssertEqual(state.lastSyncRecordCount, count)
        XCTAssertEqual(state.syncError, "Existing network error")
        XCTAssertEqual(UserDefaults.standard.data(forKey: "hkb.syncAnchors"), anchors)
    }

    func testProtectedDataRetryWiringRequiresDeferredWorkAndAvailability() {
        let state = SyncEngine.sharedSyncState
        let old = state.deferredHealthWork
        AppDelegate.sceneWorkDryRun = true
        AppDelegate.destinationConnectedOverride = true
        AppDelegate.recordedSceneWork = []
        defer {
            AppDelegate.destinationConnectedOverride = nil
            state.deferredHealthWork = old
            ProtectedHealthData.availabilityOverride = nil
            AppDelegate.sceneWorkDryRun = false
            AppDelegate.recordedSceneWork = []
        }
        state.deferredHealthWork = [.launch]
        ProtectedHealthData.availabilityOverride = false
        AppDelegate.retryDeferredHealthData()
        XCTAssertEqual(AppDelegate.recordedSceneWork, [])
        ProtectedHealthData.availabilityOverride = true
        AppDelegate.retryDeferredHealthData()
        XCTAssertEqual(AppDelegate.recordedSceneWork, ["protectedDataAvailable"])
        AppDelegate.destinationConnectedOverride = false
        AppDelegate.retryDeferredHealthData()
        XCTAssertEqual(AppDelegate.recordedSceneWork.count, 1)
        AppDelegate.destinationConnectedOverride = true
        state.deferredHealthWork = []
        AppDelegate.retryDeferredHealthData()
        XCTAssertEqual(AppDelegate.recordedSceneWork.count, 1)
        XCTAssertTrue(AppDelegate().responds(to: #selector(UIApplicationDelegate.applicationProtectedDataDidBecomeAvailable(_:))))
    }

    func testTypedProtectionErrorStopsTypeScanAndRetainsRealFailures() async throws {
        var calls = 0
        SyncEngine.syncTypeOverride = { _ in
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            throw ProtectedHealthData.unavailableError
        }
        defer { SyncEngine.syncTypeOverride = nil }
        let result = try await SyncEngine.shared.performFullSync()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.attempted, 2)
        XCTAssertTrue(result.deferred)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual((result.failures[0].error as NSError).domain, NSURLErrorDomain)
    }

    func testProtectionClassificationNeverUsesErrorText() {
        XCTAssertTrue(ProtectedHealthData.isUnavailable(ProtectedHealthData.unavailableError))
        XCTAssertFalse(ProtectedHealthData.isUnavailable(NSError(domain: "Other", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Protected health data is inaccessible"])))
        XCTAssertFalse(ProtectedHealthData.isUnavailable(URLError(.notConnectedToInternet)))
    }

    func testSignOutAndDestinationChangeInvalidateDeferredCallbacks() {
        let state = SyncEngine.sharedSyncState
        let oldAuth = state.isAuthenticated
        let oldType = state.connectionType
        let oldDeferred = state.deferredHealthWork
        defer {
            state.connectionType = oldType
            state.isAuthenticated = oldAuth
            state.deferredHealthWork = oldDeferred
        }
        state.isAuthenticated = true
        state.connectionType = .supabase
        let prior = state.healthWorkGeneration
        state.deferHealthWork(.history, generation: prior)
        XCTAssertTrue(state.healthDataDeferred)
        state.isAuthenticated = false
        XCTAssertFalse(state.healthDataDeferred)
        state.deferHealthWork(.history, generation: state.healthWorkGeneration)
        XCTAssertFalse(state.healthDataDeferred)
        state.isAuthenticated = true
        state.deferHealthWork(.history, generation: prior)
        XCTAssertFalse(state.healthDataDeferred)
        let next = state.healthWorkGeneration
        state.deferHealthWork(.history, generation: next)
        state.connectionType = oldType == .rest ? .supabase : .rest
        XCTAssertFalse(state.healthDataDeferred)
        state.deferHealthWork(.history, generation: next)
        XCTAssertFalse(state.healthDataDeferred)
        #if H4A_SHEETS
        state.connectionType = .googleSheets
        state.deferHealthWork(.history, generation: state.healthWorkGeneration)
        XCTAssertFalse(state.healthDataDeferred)
        #endif
    }
}
