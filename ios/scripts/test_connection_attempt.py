"""Run the actual adoption method with suspended import/mutex waits; no HealthKit or network."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = Path(os.environ.get("SYNC_ENGINE_SOURCE", root / "Health4AI/SyncEngine.swift")).read_text()
start = source.index("    @MainActor\n    func adoptSyncPosition")
end = source.index("    /// An install from before SyncPosition", start)
method = source[start:end]
modern = "isCurrent:" in method
invoke = ("return await engine.adoptSyncPosition(endpoint: target, isSupabase: false, isCurrent: current)"
          if modern else "await engine.adoptSyncPosition(endpoint: target, isSupabase: false); return true")
harness = r'''
import Foundation
@MainActor final class Pause {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class FakeState {
    var resets = 0
    var serverLacksMergedHours = true
    func resetSyncProgress() { resets += 1 }
}
@MainActor final class BulkExportManager {
    static let shared = BulkExportManager()
    var pause: Pause?
    var resets = 0
    func cancelAndWait() async { await pause?.wait() }
    func resetBackfill() { resets += 1 }
}
final class SyncEngine {
    @MainActor static var pause: Pause?
    static let anchorsKey = "hkb.fixtureAnchors"
    var syncAnchors = ["old": 1]
    @MainActor let syncState = FakeState()
    @MainActor init() {}
    static func serialized<T>(_ body: () async -> T) async -> T {
        await pause?.wait()
        return await body()
    }
    func resetAnchorsNow() async {
        await Self.serialized {
            self.syncAnchors.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.anchorsKey)
        }
    }
METHOD
}
@main struct Tests {
    @MainActor static func main() async {
        // Unique process suite: never use the real app's UserDefaults domain.
        let defaults = UserDefaults.standard
        let old = "https://old.invalid/api/ingest", target = "https://new.invalid/api/ingest"
        var failures = 0
        for scenario in ["switch-during-stop", "signout-during-stop", "credential-during-queue",
                         "switch-away-and-back", "cancel-during-queue", "valid"] {
            defaults.set(old, forKey: SyncPosition.endpointKey)
            defaults.set("old-anchor", forKey: SyncEngine.anchorsKey)
            let engine = SyncEngine(), pause = Pause()
            let queue = scenario.contains("queue")
            BulkExportManager.shared.pause = queue ? nil : pause
            BulkExportManager.shared.resets = 0
            SyncEngine.pause = queue ? pause : nil
            var revision = 0, generation = 0, key = "old"
            let current = { @MainActor in revision == 0 && generation == 0 && key == "old" }
            let task = Task { @MainActor in INVOKE }
            while pause.continuation == nil { await Task.yield() }
            switch scenario {
            case "switch-during-stop": revision += 1
            case "signout-during-stop": generation += 1
            case "credential-during-queue": key = "replacement"
            case "switch-away-and-back": revision += 2
            case "cancel-during-queue": task.cancel()
            default: break
            }
            pause.release()
            let adopted = await task.value
            let valid = scenario == "valid"
            let passed = adopted == valid
                && defaults.string(forKey: SyncPosition.endpointKey) == (valid ? target : old)
                && engine.syncState.resets == (valid ? 1 : 0)
                && BulkExportManager.shared.resets == (valid ? 1 : 0)
                && engine.syncAnchors.isEmpty == valid
                && (defaults.string(forKey: SyncEngine.anchorsKey) == nil) == valid
            print("\(passed ? "PASS" : "FAIL") \(scenario)")
            if !passed { failures += 1 }
        }
        defaults.removeObject(forKey: SyncPosition.endpointKey)
        defaults.removeObject(forKey: SyncEngine.anchorsKey)
        exit(failures == 0 ? 0 : 1)
    }
}
'''.replace("METHOD", method).replace("INVOKE", invoke)
with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    (folder / "Harness.swift").write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(root / "Health4AI/SyncPosition.swift"),
                    str(folder / "Harness.swift"), "-o", str(folder / "checks")], check=True)
    subprocess.run([str(folder / "checks")], check=True, cwd=tmp)
