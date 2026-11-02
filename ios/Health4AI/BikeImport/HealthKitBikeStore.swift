import Foundation
import HealthKit

// HealthKit side of the bike import: the only place in the app that WRITES to Health. Share
// authorization is requested here, on opt-in, never in HealthKitManager's read flow.

final class HealthKitBikeStore: BikeWorkoutStore {
    private let store = HKHealthStore()

    private var energy: HKQuantityType { HKQuantityType(.activeEnergyBurned) }
    private var distance: HKQuantityType { HKQuantityType(.distanceCycling) }
    private var power: HKQuantityType { HKQuantityType(.cyclingPower) }        // iOS 17+; deployment target is 17.0
    private var cadence: HKQuantityType { HKQuantityType(.cyclingCadence) }    // iOS 17+
    private var heartRate: HKQuantityType { HKQuantityType(.heartRate) }

    /// The five types that must ALL be writable before anything is saved, with the names shown to the person.
    private var coreTypes: [(name: String, type: HKObjectType)] {
        [("Workouts", HKObjectType.workoutType()), ("Active energy", energy), ("Cycling distance", distance),
         ("Cycling power", power), ("Cycling cadence", cadence)]
    }

    private func status(_ type: HKObjectType) -> BikeWriteStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        switch store.authorizationStatus(for: type) {
        case .sharingAuthorized: return .authorized
        case .sharingDenied: return .denied
        default: return .notDetermined
        }
    }

    var coreAccess: BikeCoreAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return BikeCoreAccess(unavailable: true) }
        var access = BikeCoreAccess()
        for (name, type) in coreTypes {
            switch status(type) {
            case .authorized: break
            case .denied: access.denied.append(name)
            default: access.notDetermined.append(name)
            }
        }
        return access
    }

    var heartRateWriteStatus: BikeWriteStatus { status(heartRate) }

    /// Heart rate is deliberately absent. Workouts are also requested for READ: the app's existing read
    /// purpose already covers them, and it makes the sync-identifier de-duplication query reliable.
    func requestCoreAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw BikeImportError.healthUnavailable }
        let share = Set(coreTypes.compactMap { $0.type as? HKSampleType })
        try await store.requestAuthorization(toShare: share, read: [HKObjectType.workoutType()])
    }

    func requestHeartRateAuthorization() async throws {
        try await store.requestAuthorization(toShare: [heartRate], read: [])
    }

    func existingSyncIdentifiers(among ids: [String]) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: ids)
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [])
        let found = try await descriptor.result(for: store)
        return Set(found.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String })
    }

    func save(_ plan: BikeWorkoutPlan) async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .indoor
        let device = HKDevice(name: "Peloton Pi", manufacturer: nil, model: nil, hardwareVersion: nil,
                              firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: device)
        let withHR = plan.writeHeartRate && status(heartRate) == .authorized

        do {
            try await builder.beginCollection(at: plan.start)
            try await builder.addMetadata([
                HKMetadataKeyIndoorWorkout: true,
                HKMetadataKeySyncIdentifier: plan.syncIdentifier,
                HKMetadataKeySyncVersion: BikeRideID.syncVersion,
                HKMetadataKeyExternalUUID: plan.rideID,
            ])
            var samples: [HKSample] = []
            for (i, b) in plan.buckets.enumerated() {
                let s = plan.start.addingTimeInterval(TimeInterval(b.startOffset))
                let e = plan.start.addingTimeInterval(TimeInterval(b.endOffset))
                func q(_ type: HKQuantityType, _ unit: HKUnit, _ value: Double) -> HKQuantitySample {
                    HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: s, end: e)
                }
                if plan.kcalPerBucket[i] > 0 { samples.append(q(energy, .kilocalorie(), plan.kcalPerBucket[i])) }
                if plan.metersPerBucket[i] > 0 { samples.append(q(distance, .meter(), plan.metersPerBucket[i])) }
                samples.append(q(power, .watt(), b.power))
                samples.append(q(cadence, HKUnit.count().unitDivided(by: .minute()), b.cadence))
                if withHR, let hr = b.heartRate { samples.append(q(heartRate, HKUnit.count().unitDivided(by: .minute()), hr)) }
            }
            try await builder.addSamples(samples)
            try await builder.endCollection(at: plan.end)
        } catch {
            builder.discardWorkout()
            throw error
        }

        // finishWorkout() can return nil without an error (for example while the device is locked) even
        // though the workout was written. Ask Health rather than guess in either direction.
        if try await builder.finishWorkout() == nil {
            let found = try await existingSyncIdentifiers(among: [plan.syncIdentifier])
            guard found.contains(plan.syncIdentifier) else { throw BikeImportError.saveUnconfirmed(plan.rideID) }
        }
    }
}
