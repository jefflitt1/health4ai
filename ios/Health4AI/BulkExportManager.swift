import Foundation
import HealthKit
import UIKit

// MARK: - BulkExportManager

/// Manages the one-time historical backfill of all HealthKit data.
/// On first launch after auth, queries ALL historical HKSamples (no date limit)
/// and POSTs them in batches of 500, tracking progress in UserDefaults.
final class BulkExportManager {

    @MainActor static let shared = BulkExportManager()

    private let hkManager = HealthKitManager.shared
    private let syncEngine: SyncEngine

    // Tracks which types have been fully backfilled
    private static let completedTypesKey = "hkb.backfill.completedTypes"
    private static let backfillInProgressKey = "hkb.backfill.inProgress"
    // Per-type chunk checkpoint: saves the last completed chunkEnd so restarts resume mid-type
    private static let chunkCheckpointPrefix = "hkb.backfill.chunk."

    // UIKit background task token — keeps the app alive ~30s after going to background
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    private var completedTypes: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: Self.completedTypesKey) ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.completedTypesKey)
        }
    }

    private var currentTask: Task<Void, Never>? = nil

    @MainActor private init() {
        self.syncEngine = SyncEngine.shared
    }

    // MARK: - Should we run a backfill?

    var backfillNeeded: Bool {
        let completed = UserDefaults.standard.bool(forKey: "hkb.backfillCompleted")
        return !completed
    }

    // MARK: - Start backfill

    /// Begins (or resumes) the full historical backfill.
    /// Safe to call multiple times — skips already-completed types.
    func startBackfill(syncState: SyncState) {
        guard currentTask == nil else { return } // Already running

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await MainActor.run {
                syncState.isBackfilling = true
                syncState.backfillError = nil
            }
            await self.runBackfill(syncState: syncState)
            self.currentTask = nil
        }
    }

    func cancelBackfill() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Backfill execution

    private func runBackfill(syncState: SyncState) async {
        let allTypes = HealthKitManager.allSampleTypes()
        let remainingTypes = allTypes.filter { !completedTypes.contains($0.identifier) }

        // Estimate total by querying counts (fast path: just run the sync and count)
        var totalSynced = 0
        let totalTypes = remainingTypes.count
        var typesCompleted = 0

        let serverURL = await MainActor.run { syncState.resolvedEndpointURL }

        for sampleType in remainingTypes {
            if Task.isCancelled { break }

            do {
                let count = try await backfillType(
                    sampleType: sampleType,
                    serverURL: serverURL,
                    onBatch: { batchCount, earliestDate, latestDate in
                        totalSynced += batchCount
                        Task { @MainActor in
                            syncState.recordBackfillProgress(
                                synced: totalSynced,
                                total: max(totalSynced, syncState.backfillTotalRecords),
                                earliest: earliestDate,
                                latest: latestDate
                            )
                        }
                    }
                )

                // Mark this type as done
                var completed = completedTypes
                completed.insert(sampleType.identifier)
                completedTypes = completed
                typesCompleted += 1

                print("[BulkExport] \(sampleType.identifier): \(count) records (\(typesCompleted)/\(totalTypes) types)")

            } catch is CancellationError {
                break
            } catch {
                // Log per-type errors but continue with other types
                print("[BulkExport] Error on \(sampleType.identifier): \(error)")
            }
        }

        if !Task.isCancelled {
            // Mark global backfill complete
            await MainActor.run {
                syncState.recordBackfillComplete()
            }
            print("[BulkExport] Backfill complete. Total records: \(totalSynced)")
        } else {
            await MainActor.run {
                syncState.isBackfilling = false
            }
        }
    }

    // MARK: - Per-type backfill

    /// Queries historical samples for a type in 90-day chunks to keep memory bounded.
    /// Loading all records at once (400K+ for steps/HR) causes iOS OOM kills.
    /// Each chunk is queried, converted, posted, and released before the next chunk loads.
    private func backfillType(
        sampleType: HKSampleType,
        serverURL: String,
        onBatch: @escaping (_ count: Int, _ earliest: Date?, _ latest: Date?) -> Void
    ) async throws -> Int {
        let token: String
        do {
            token = try await SyncEngine.sharedAuthManager.validToken(serverURL: serverURL)
        } catch {
            throw SyncError.authFailed(error.localizedDescription)
        }

        let calendar = Calendar.current
        let floor = DateComponents(calendar: calendar, year: 2013, month: 1, day: 1).date!
        let now = Date()
        let chunkDays = 90
        var totalCount = 0

        // Resume from last saved checkpoint if the app was killed mid-type
        let checkpointKey = Self.chunkCheckpointPrefix + sampleType.identifier
        let checkpointTS = UserDefaults.standard.double(forKey: checkpointKey)
        var chunkStart = checkpointTS > 0 ? Date(timeIntervalSince1970: checkpointTS) : floor

        while chunkStart < now {
            if Task.isCancelled { break }

            let chunkEnd = min(calendar.date(byAdding: .day, value: chunkDays, to: chunkStart)!, now)

            let samples: [HKSample]
            do {
                samples = try await hkManager.querySamples(
                    type: sampleType,
                    startDate: chunkStart,
                    endDate: chunkEnd,
                    limit: HKObjectQueryNoLimit
                )
            } catch {
                // HKError code 5 = no data for this type/window — skip quietly
                chunkStart = chunkEnd
                UserDefaults.standard.set(chunkEnd.timeIntervalSince1970, forKey: checkpointKey)
                continue
            }

            if !samples.isEmpty {
                let healthSamples = samples.compactMap { hkManager.convert(sample: $0) }

                if !healthSamples.isEmpty {
                    let batchSize = SyncEngine.batchSize
                    let batches = stride(from: 0, to: healthSamples.count, by: batchSize).map {
                        Array(healthSamples[$0..<min($0 + batchSize, healthSamples.count)])
                    }

                    for batch in batches {
                        if Task.isCancelled { break }
                        try await syncEngine.postSamples(batch, token: token, serverURL: serverURL)
                        onBatch(batch.count, nil, nil)
                        totalCount += batch.count
                    }
                }
            }

            chunkStart = chunkEnd
            // Save checkpoint after each chunk so kills resume here, not from 2013
            UserDefaults.standard.set(chunkEnd.timeIntervalSince1970, forKey: checkpointKey)
        }

        // Clear checkpoint once type is fully complete
        UserDefaults.standard.removeObject(forKey: checkpointKey)
        return totalCount
    }

    // MARK: - Background task support (disabled on iOS 27 Beta)
    // BackgroundTasks.framework triggers _libxpc_initializer XPC crash on iOS 27 Beta.
    // Restore registerBackgroundBackfillTask() + scheduleBackgroundBackfill() when fixed.

    /// Request ~30 seconds of background execution time when the app transitions to background.
    /// This lets the current 90-day chunk finish rather than being cut off mid-upload.
    func requestBackgroundTime() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "HK Backfill Chunk") { [weak self] in
            self?.endBackgroundTime()
        }
    }

    func endBackgroundTime() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    // MARK: - Reset backfill state (for re-running)

    func resetBackfill() {
        completedTypes = []
        UserDefaults.standard.removeObject(forKey: "hkb.backfillCompleted")
        UserDefaults.standard.removeObject(forKey: "hkb.backfillProgress")
        UserDefaults.standard.removeObject(forKey: Self.backfillInProgressKey)
        // Clear all per-type chunk checkpoints
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.chunkCheckpointPrefix) }
            .forEach { defaults.removeObject(forKey: $0) }
        cancelBackfill()
    }
}
