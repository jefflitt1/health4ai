import Foundation

// The import logic, free of HealthKit and URLSession so tests drive it with fakes.
// Dedupe truth is HealthKit (sync identifier on the saved workout), never local bookkeeping:
// a ride is "imported" only if Health holds it, so a reinstall cannot duplicate and a failed save
// cannot be remembered as done.

enum BikeWriteStatus: Equatable {
    case notDetermined, authorized, denied, unavailable
}

/// Everything the store needs to write one ride. Built by `BikeWorkoutPlan.make`.
struct BikeWorkoutPlan: Equatable {
    let rideID: String
    let syncIdentifier: String
    let start: Date
    let end: Date
    let totalKcal: Double
    let totalMeters: Double
    let buckets: [BikeBucket]
    let kcalPerBucket: [Double]
    let metersPerBucket: [Double]
    /// Set by the importer once heart-rate write access is confirmed; false drops HR samples.
    var writeHeartRate: Bool

    var hasHeartRate: Bool { buckets.contains { $0.heartRate != nil } }

    static let metersPerMile = 1609.344

    static func make(from ride: BikeRide) throws -> BikeWorkoutPlan {
        let id = ride.summary.id
        guard let start = BikeRideID.startDate(from: id) else { throw BikeImportError.badRideID(id) }
        guard !ride.samples.isEmpty else { throw BikeImportError.noSamples }
        let buckets = BikeSampleAggregator.buckets(samples: ride.samples, elapsed: ride.summary.elapsed)
        guard let last = buckets.last else { throw BikeImportError.noSamples }
        let kcal = max(ride.summary.calories, 0)
        let meters = max(ride.summary.distanceMi, 0) * metersPerMile
        return BikeWorkoutPlan(
            rideID: id, syncIdentifier: BikeRideID.syncIdentifier(for: id),
            start: start, end: start.addingTimeInterval(TimeInterval(last.endOffset)),
            totalKcal: kcal, totalMeters: meters, buckets: buckets,
            kcalPerBucket: BikeSampleAggregator.allocate(total: kcal, over: buckets, weight: \.workWeight),
            metersPerBucket: BikeSampleAggregator.allocate(total: meters, over: buckets, weight: \.distanceWeight),
            writeHeartRate: false)
    }
}

protocol BikeWorkoutStore {
    var workoutWriteStatus: BikeWriteStatus { get }
    var heartRateWriteStatus: BikeWriteStatus { get }
    func requestCoreAuthorization() async throws
    func requestHeartRateAuthorization() async throws
    /// The subset of `ids` already saved to Health by this app.
    func existingSyncIdentifiers(among ids: [String]) async throws -> Set<String>
    /// Saves one workout. Returns the names of sample types skipped because the person denied them.
    func save(_ plan: BikeWorkoutPlan) async throws -> [String]
}

protocol BikeRideAPI {
    func listRides() async throws -> [BikeRideSummary]
    func ride(id: String) async throws -> BikeRide
}

enum BikeImportError: Error, Equatable, LocalizedError {
    case noSamples
    case badRideID(String)
    case permissionDenied
    case permissionNotRequested
    case healthUnavailable

    var errorDescription: String? {
        switch self {
        case .noSamples: return "the bike recorded no samples for this ride"
        case .badRideID(let id): return "ride id \"\(id)\" is not a timestamp"
        case .permissionDenied:
            return "Health write access is off for health4ai. Turn on Workouts in Health > Sharing > Apps > health4ai."
        case .permissionNotRequested: return "Health write access has not been granted yet. Turn the switch off and on again."
        case .healthUnavailable: return "Apple Health is not available on this device."
        }
    }
}

struct BikeImportResult: Codable, Equatable {
    var date: Date
    var imported = 0
    var alreadyImported = 0
    /// "<ride id>: <reason>" for rides left alone on purpose (e.g. no samples).
    var skipped: [String] = []
    /// "<ride id>: <error>" for rides that should have imported and did not.
    var failed: [String] = []
    /// Notes about partial writes, e.g. a sample type the person denied.
    var notes: [String] = []
    /// Set when the run could not proceed at all (Pi unreachable, permission off). Never a success.
    var error: String?

    var isSuccess: Bool { error == nil && failed.isEmpty }
}

struct BikeImporter {
    let api: BikeRideAPI
    let store: BikeWorkoutStore
    var now: () -> Date = Date.init

    func run() async -> BikeImportResult {
        var result = BikeImportResult(date: now())
        switch store.workoutWriteStatus {
        case .authorized: break
        case .denied: result.error = BikeImportError.permissionDenied.localizedDescription; return result
        case .notDetermined: result.error = BikeImportError.permissionNotRequested.localizedDescription; return result
        case .unavailable: result.error = BikeImportError.healthUnavailable.localizedDescription; return result
        }

        let rides: [BikeRideSummary]
        do { rides = try await api.listRides() } catch {
            result.error = error.localizedDescription
            return result
        }

        let known: Set<String>
        do {
            known = try await store.existingSyncIdentifiers(among: rides.map { BikeRideID.syncIdentifier(for: $0.id) })
        } catch {
            result.error = "Could not check Health for rides already imported: \(error.localizedDescription)"
            return result
        }

        for summary in rides.sorted(by: { $0.id < $1.id }) {
            if known.contains(BikeRideID.syncIdentifier(for: summary.id)) { result.alreadyImported += 1; continue }
            await importOne(summary, into: &result)
        }
        return result
    }

    private func importOne(_ summary: BikeRideSummary, into result: inout BikeImportResult) async {
        let id = summary.id
        guard BikeRideID.startDate(from: id) != nil else {
            result.skipped.append("\(id): \(BikeImportError.badRideID(id).localizedDescription)")
            return
        }
        do {
            let ride = try await api.ride(id: id)
            guard ride.summary.id == id else {
                result.failed.append("\(id): the bike returned a different ride (\(ride.summary.id))")
                return
            }
            var plan: BikeWorkoutPlan
            do { plan = try BikeWorkoutPlan.make(from: ride) } catch BikeImportError.noSamples {
                result.skipped.append("\(id): \(BikeImportError.noSamples.localizedDescription)")
                return
            }
            if plan.hasHeartRate { plan.writeHeartRate = await heartRateAllowed(id: id, into: &result) }
            let skippedTypes = try await store.save(plan)
            result.imported += 1
            if !skippedTypes.isEmpty {
                result.notes.append("\(id): not saved because access is off: \(skippedTypes.joined(separator: ", "))")
            }
        } catch {
            result.failed.append("\(id): \(error.localizedDescription)")
        }
    }

    /// Heart rate is asked for lazily, only when a ride actually has HR (it is not in the up-front prompt).
    private func heartRateAllowed(id: String, into result: inout BikeImportResult) async -> Bool {
        if store.heartRateWriteStatus == .notDetermined {
            do { try await store.requestHeartRateAuthorization() } catch {
                result.notes.append("\(id): heart rate not saved: \(error.localizedDescription)")
                return false
            }
        }
        if store.heartRateWriteStatus == .authorized { return true }
        result.notes.append("\(id): heart rate not saved because access is off")
        return false
    }
}
