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
    /// A rule about the ride's CONTENT failed. May be remembered as a permanent rejection.
    case invalidRide(String)
    /// The ride's date failed the date rule. Depends on the clock, so it is NEVER remembered.
    case invalidDate(String)
    case coreAccessMissing([String])
    case permissionNotRequested
    case healthUnavailable
    case saveUnconfirmed(String)

    var errorDescription: String? {
        switch self {
        case .noSamples: return "The bike recorded no samples"
        case .badRideID: return "The bike gave an id health4ai cannot read"
        case .invalidRide(let why), .invalidDate(let why): return "Rejected, \(why)"
        case .coreAccessMissing(let names):
            return "Health write access is off for: \(names.joined(separator: ", ")). "
                + "Turn them on in the Health app (your profile picture, then Apps, then health4ai)."
        case .permissionNotRequested: return "Health write access has not been granted yet. Turn Import on to be asked."
        case .healthUnavailable: return "Apple Health is not available on this device."
        case .saveUnconfirmed:
            return "Health did not confirm the save (the phone may be locked); it will be checked again next import"
        }
    }
}

/// One ride (or the whole run, when `rideID` is nil) and a plain-language reason. Never raw system error text.
struct BikeIssue: Codable, Equatable {
    var rideID: String?
    var reason: String
}

enum BikeRunErrorKind: String, Codable, Equatable {
    /// Health write access is off for some types (the permission message on screen already says so).
    case coreAccessMissing
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
    /// Which kind of run error, so the screen can decide what to hide without comparing strings.
    var errorKind: BikeRunErrorKind?

    var isSuccess: Bool { error == nil && failed.isEmpty && unconfirmed.isEmpty }
}

struct BikeImporter {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "BikeImport")

    enum Operation { case bike, health }

    /// Text safe to show: our own errors speak for themselves; anything else (HealthKit, Foundation)
    /// is logged in full and shown as a plain sentence, never as a domain or code. The fallback names the
    /// right culprit: a bike read must not tell the person to unlock Health.
    static func reason(for error: Error, doing what: String, kind: Operation) -> String {
        if error is BikeImportError || error is BikeClientError { return error.localizedDescription }
        logger.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return "The import was interrupted before it finished. It will run again next time."
        }
        switch kind {
        case .bike: return "Could not \(what). Check that the bike is on and on the same Wi-Fi, then try again."
        case .health: return "Health could not \(what). Check that Health is unlocked and try again."
        }
    }

    let api: BikeRideAPI
    let store: BikeWorkoutStore
    var now: () -> Date = Date.init
    var maxRides = BikeLimits.maxRidesPerImport
    /// Rides rejected for good. In memory unless the app passes the UserDefaults-backed one.
    var rejectedStore: BikeRejectedStore = MemoryRejectedStore()
    /// Asked before each ride is fetched and saved. False stops the import there: the person erased the
    /// app's data while it ran, and no further ride may be written to Health (review 2026-11-09).
    var shouldContinue: () async -> Bool = { true }

    func run() async -> BikeImportResult {
        var result = BikeImportResult(date: now())
        let access = store.coreAccess
        if access.unavailable { result.error = BikeImportError.healthUnavailable.localizedDescription; return result }
        if !access.denied.isEmpty {
            result.error = BikeImportError.coreAccessMissing(access.missing).localizedDescription
            result.errorKind = .coreAccessMissing
            return result
        }
        if !access.notDetermined.isEmpty { result.error = BikeImportError.permissionNotRequested.localizedDescription; return result }

        let rides: [BikeRideSummary]
        do { rides = try await api.listRides() } catch {
            result.error = Self.reason(for: error, doing: "read the bike", kind: .bike)
            return result
        }

        let known: Set<String>
        do {
            known = try await store.existingSyncIdentifiers(among: rides.filter { BikeRideID.startDate(from: $0.id) != nil }.map { BikeRideID.syncIdentifier(for: $0.id) })
        } catch {
            result.error = Self.reason(for: error, doing: "check which rides are already imported", kind: .health)
            return result
        }

        // Sort out everything that needs no network call BEFORE the cap, so none of it can use a slot:
        // ids that are not timestamps, dates outside the allowed range, rides already in Health, and rides
        // rejected for good on an earlier import (remembered, so they are not fetched again).
        var rejected = rejectedStore.load()
        var candidates: [(summary: BikeRideSummary, start: Date)] = []
        for summary in rides {
            guard let start = BikeRideID.startDate(from: summary.id) else {
                Self.logger.error("skipped a ride whose id is not a timestamp: \(summary.id, privacy: .public)")
                result.skipped.append(BikeIssue(rideID: summary.id, reason: BikeImportError.badRideID(summary.id).localizedDescription))
                continue
            }
            if known.contains(BikeRideID.syncIdentifier(for: summary.id)) { result.alreadyImported += 1; continue }
            if let problem = BikeRideValidator.dateProblem(start: start, now: now()) {
                result.skipped.append(BikeIssue(rideID: summary.id, reason: BikeImportError.invalidDate(problem).localizedDescription))
                continue
            }
            // Skipped without a fetch only while the listing still looks exactly as it did when it was rejected.
            if rejected[summary.id]?.holds(for: BikeFingerprint.of(summary), now: now()) == true {
                Self.logger.info("not retrying ride \(summary.id, privacy: .public): rejected on an earlier import and unchanged")
                continue
            }
            candidates.append((summary, start))
        }
        // Newest first by the parsed start time (never by string). The cap counts rides actually FETCHED,
        // so rides skipped without a fetch cost nothing; the older backlog follows on later imports.
        candidates.sort { $0.start != $1.start ? $0.start > $1.start : $0.summary.id > $1.summary.id }
        if candidates.count > maxRides {
            result.notes.append(BikeIssue(rideID: nil, reason: "\(candidates.count - maxRides) older rides were left for the next import (limit \(maxRides) per import)"))
            candidates = Array(candidates.prefix(maxRides))
        }
        for c in candidates {
            guard await shouldContinue() else { return result }
            await importOne(c.summary, into: &result, rejected: &rejected)
        }
        // Forget ids the bike no longer lists, so the set cannot grow without bound.
        let listed = Set(rides.map(\.id))
        rejectedStore.save(rejected.filter { listed.contains($0.key) })
        return result
    }

    /// A ride that ended this recently may still be being written, so a content rejection is not trusted yet.
    static let liveWindow: TimeInterval = 600

    private func importOne(_ summary: BikeRideSummary, into result: inout BikeImportResult, rejected: inout [String: BikeRejection]) async {
        let id = summary.id
        rejected[id] = nil   // re-decided below; a stale fingerprint must not outlive a refetch
        let ride: BikeRide
        do { ride = try await api.ride(id: id) } catch {
            result.failed.append(BikeIssue(rideID: id, reason: Self.reason(for: error, doing: "read this ride from the bike", kind: .bike)))
            return
        }
        guard ride.summary.id == id else {
            result.failed.append(BikeIssue(rideID: id, reason: "The bike returned a different ride than the one asked for"))
            return
        }
        do {
            var plan: BikeWorkoutPlan
            do { plan = try BikeWorkoutPlan.make(from: ride, now: now()) } catch let error as BikeImportError {
                switch error {
                case .noSamples, .invalidRide:
                    result.skipped.append(BikeIssue(rideID: id, reason: error.localizedDescription))
                    // Decided by the ride's own content: remember it against this exact listing, unless the
                    // ride only just ended (it may still be written to).
                    // An elapsed outside the allowed range is a content rule that more time cannot fix, so it is
                    // remembered at once; otherwise the elapsed used for the window is clamped to the limit so
                    // an absurd value cannot push "ended" into the far future.
                    let rangeProblem = !BikeLimits.elapsed.contains(summary.elapsed)
                    let clamped = min(max(summary.elapsed, BikeLimits.elapsed.lowerBound), BikeLimits.elapsed.upperBound)
                    let ended = (BikeRideID.startDate(from: id) ?? .distantPast).addingTimeInterval(TimeInterval(clamped))
                    if rangeProblem || ended <= now().addingTimeInterval(-Self.liveWindow) {
                        rejected[id] = BikeRejection(fingerprint: BikeFingerprint.of(summary), at: now())
                    }
                    return
                case .invalidDate:
                    result.skipped.append(BikeIssue(rideID: id, reason: error.localizedDescription))
                    return   // the date rule depends on the clock: never remembered

                default: throw error
                }
            }
            if plan.hasHeartRate { plan.writeHeartRate = await heartRateAllowed(id: id, into: &result) }
            try await store.save(plan)
            result.imported += 1
        } catch BikeImportError.saveUnconfirmed(let rideID) {
            result.unconfirmed.append(BikeIssue(rideID: rideID, reason: BikeImportError.saveUnconfirmed(rideID).localizedDescription))
        } catch {
            result.failed.append(BikeIssue(rideID: id, reason: Self.reason(for: error, doing: "save the workout data", kind: .health)))
        }
    }

    /// Heart rate is asked for lazily, only when a ride actually has HR (it is not in the up-front prompt).
    /// It is optional by design, and a ride saved without it can never get it later (its sync identifier
    /// is taken), so the note says so.
    private func heartRateAllowed(id: String, into result: inout BikeImportResult) async -> Bool {
        let tail = BikeCopy.heartRateCannotBeAddedLater
        if store.heartRateWriteStatus == .notDetermined {
            do { try await store.requestHeartRateAuthorization() } catch {
                Self.logger.error("heart rate authorization failed: \(String(describing: error), privacy: .public)")
                result.notes.append(BikeIssue(rideID: id, reason: "Heart rate could not be requested. \(tail)"))
                return false
            }
        }
        if store.heartRateWriteStatus == .authorized { return true }
        result.notes.append(BikeIssue(rideID: id, reason: "Heart rate access is off. \(tail)"))
        return false
    }
}
