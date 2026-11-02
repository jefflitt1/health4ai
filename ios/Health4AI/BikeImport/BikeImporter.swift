import Foundation
import os

// The import logic, free of HealthKit and URLSession so tests drive it with fakes.
// Dedupe truth is HealthKit (sync identifier on the saved workout), never local bookkeeping:
// a ride is "imported" only if Health holds it, so a reinstall cannot duplicate and a failed save
// cannot be remembered as done.

enum BikeWriteStatus: Equatable {
    case notDetermined, authorized, denied, unavailable
}

/// Write access to the five core types (workout, active energy, cycling distance, power, cadence).
/// All five are required: a ride saved without one would carry the sync identifier and never get it later.
struct BikeCoreAccess: Equatable {
    var denied: [String] = []
    var notDetermined: [String] = []
    var unavailable = false

    var isComplete: Bool { denied.isEmpty && notDetermined.isEmpty && !unavailable }
    var missing: [String] { denied + notDetermined }
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

    static func make(from ride: BikeRide, now: Date = Date()) throws -> BikeWorkoutPlan {
        let id = ride.summary.id
        guard let start = BikeRideID.startDate(from: id) else { throw BikeImportError.badRideID(id) }
        guard !ride.samples.isEmpty else { throw BikeImportError.noSamples }
        try BikeRideValidator.validate(ride, start: start, now: now)
        let buckets = BikeSampleAggregator.buckets(samples: ride.samples, elapsed: ride.summary.elapsed)
        guard !buckets.isEmpty else { throw BikeImportError.noSamples }
        let kcal = max(ride.summary.calories, 0)
        let meters = max(ride.summary.distanceMi, 0) * metersPerMile
        // The workout runs for the summary's full length (the length its calories and distance cover),
        // even if samples stop early; every bucket lies inside [start, end].
        return BikeWorkoutPlan(
            rideID: id, syncIdentifier: BikeRideID.syncIdentifier(for: id),
            start: start, end: start.addingTimeInterval(TimeInterval(ride.summary.elapsed)),
            totalKcal: kcal, totalMeters: meters, buckets: buckets,
            kcalPerBucket: BikeSampleAggregator.allocate(total: kcal, over: buckets, weight: \.workWeight),
            metersPerBucket: BikeSampleAggregator.allocate(total: meters, over: buckets, weight: \.distanceWeight),
            writeHeartRate: false)
    }
}

protocol BikeWorkoutStore {
    var coreAccess: BikeCoreAccess { get }
    var heartRateWriteStatus: BikeWriteStatus { get }
    func requestCoreAuthorization() async throws
    func requestHeartRateAuthorization() async throws
    /// The subset of `ids` already saved to Health by this app.
    func existingSyncIdentifiers(among ids: [String]) async throws -> Set<String>
    /// Saves one workout. Throws `BikeImportError.saveUnconfirmed` if Health neither reported success
    /// nor shows the workout afterwards.
    func save(_ plan: BikeWorkoutPlan) async throws
}

protocol BikeRideAPI {
    func listRides() async throws -> [BikeRideSummary]
    func ride(id: String) async throws -> BikeRide
}

enum BikeImportError: Error, Equatable, LocalizedError {
    case noSamples
    case badRideID(String)
    case invalidRide(String)
    case coreAccessMissing([String])
    case permissionNotRequested
    case healthUnavailable
    case saveUnconfirmed(String)

    var errorDescription: String? {
        switch self {
        case .noSamples: return "the bike recorded no samples for this ride"
        case .badRideID(let id): return "ride id \"\(id)\" is not a timestamp"
        case .invalidRide(let why): return "rejected, \(why)"
        case .coreAccessMissing(let names):
            return "Health write access is off for: \(names.joined(separator: ", ")). "
                + "Turn them on in the Health app (your profile picture, then Apps, then health4ai)."
        case .permissionNotRequested: return "Health write access has not been granted yet. Turn Import on to be asked."
        case .healthUnavailable: return "Apple Health is not available on this device."
        case .saveUnconfirmed(let id):
            return "Health did not confirm saving this ride (the phone may be locked); it will be checked again next import"
        }
    }
}

/// One ride (or the whole run, when `rideID` is nil) and a plain-language reason. Never raw system error text.
struct BikeIssue: Codable, Equatable {
    var rideID: String?
    var reason: String
}

struct BikeImportResult: Codable, Equatable {
    var date: Date
    var imported = 0
    var alreadyImported = 0
    /// Rides left alone on purpose (no samples, values out of range).
    var skipped: [BikeIssue] = []
    /// Rides that should have imported and did not.
    var failed: [BikeIssue] = []
    /// Rides whose save Health did not confirm either way. Not counted as imported; re-checked next time.
    var unconfirmed: [BikeIssue] = []
    /// Partial writes (heart rate not saved) and limits applied.
    var notes: [BikeIssue] = []
    /// Set when the run could not proceed at all (Pi unreachable, permission off). Never a success.
    var error: String?

    var isSuccess: Bool { error == nil && failed.isEmpty && unconfirmed.isEmpty }
}

struct BikeImporter {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "BikeImport")

    /// Text safe to show: our own errors speak for themselves; anything else (HealthKit, Foundation)
    /// is logged in full and shown as a plain sentence, never as a domain or code.
    static func reason(for error: Error, doing what: String) -> String {
        if error is BikeImportError || error is BikeClientError { return error.localizedDescription }
        logger.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        return "Health could not \(what). Check that Health is unlocked and try again."
    }

    let api: BikeRideAPI
    let store: BikeWorkoutStore
    var now: () -> Date = Date.init
    var maxRides = BikeLimits.maxRidesPerImport

    func run() async -> BikeImportResult {
        var result = BikeImportResult(date: now())
        let access = store.coreAccess
        if access.unavailable { result.error = BikeImportError.healthUnavailable.localizedDescription; return result }
        if !access.denied.isEmpty { result.error = BikeImportError.coreAccessMissing(access.missing).localizedDescription; return result }
        if !access.notDetermined.isEmpty { result.error = BikeImportError.permissionNotRequested.localizedDescription; return result }

        let rides: [BikeRideSummary]
        do { rides = try await api.listRides() } catch {
            result.error = Self.reason(for: error, doing: "read the bike")
            return result
        }

        let known: Set<String>
        do {
            known = try await store.existingSyncIdentifiers(among: rides.map { BikeRideID.syncIdentifier(for: $0.id) })
        } catch {
            result.error = Self.reason(for: error, doing: "check which rides are already imported")
            return result
        }

        var pending: [BikeRideSummary] = []
        for summary in rides.sorted(by: { $0.id < $1.id }) {
            if known.contains(BikeRideID.syncIdentifier(for: summary.id)) { result.alreadyImported += 1 } else { pending.append(summary) }
        }
        if pending.count > maxRides {
            result.notes.append(BikeIssue(rideID: nil, reason: "\(pending.count - maxRides) newer rides were left for the next import (limit \(maxRides) per import)"))
            pending = Array(pending.prefix(maxRides))
        }
        for summary in pending { await importOne(summary, into: &result) }
        return result
    }

    private func importOne(_ summary: BikeRideSummary, into result: inout BikeImportResult) async {
        let id = summary.id
        guard BikeRideID.startDate(from: id) != nil else {
            result.skipped.append(BikeIssue(rideID: id, reason: BikeImportError.badRideID(id).localizedDescription))
            return
        }
        do {
            let ride = try await api.ride(id: id)
            guard ride.summary.id == id else {
                result.failed.append(BikeIssue(rideID: id, reason: "the bike returned a different ride than the one asked for"))
                return
            }
            var plan: BikeWorkoutPlan
            do { plan = try BikeWorkoutPlan.make(from: ride, now: now()) } catch let error as BikeImportError {
                switch error {
                case .noSamples, .invalidRide:
                    result.skipped.append(BikeIssue(rideID: id, reason: error.localizedDescription))
                    return
                default: throw error
                }
            }
            if plan.hasHeartRate { plan.writeHeartRate = await heartRateAllowed(id: id, into: &result) }
            try await store.save(plan)
            result.imported += 1
        } catch BikeImportError.saveUnconfirmed(let rideID) {
            result.unconfirmed.append(BikeIssue(rideID: rideID, reason: BikeImportError.saveUnconfirmed(rideID).localizedDescription))
        } catch {
            result.failed.append(BikeIssue(rideID: id, reason: Self.reason(for: error, doing: "save this ride")))
        }
    }

    /// Heart rate is asked for lazily, only when a ride actually has HR (it is not in the up-front prompt).
    /// It is optional by design, and a ride saved without it can never get it later (its sync identifier
    /// is taken), so the note says so.
    private func heartRateAllowed(id: String, into result: inout BikeImportResult) async -> Bool {
        let tail = "this ride was imported without heart rate and will not get it later"
        if store.heartRateWriteStatus == .notDetermined {
            do { try await store.requestHeartRateAuthorization() } catch {
                Self.logger.error("heart rate authorization failed: \(String(describing: error), privacy: .public)")
                result.notes.append(BikeIssue(rideID: id, reason: "heart rate could not be requested; \(tail)"))
                return false
            }
        }
        if store.heartRateWriteStatus == .authorized { return true }
        result.notes.append(BikeIssue(rideID: id, reason: "heart rate access is off; \(tail)"))
        return false
    }
}
