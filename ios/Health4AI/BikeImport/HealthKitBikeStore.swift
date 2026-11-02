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

    /// Types requested when the person turns the feature on. Heart rate is deliberately absent.
    var coreShareTypes: Set<HKSampleType> { [HKObjectType.workoutType(), energy, distance, power, cadence] }

    private func status(_ type: HKObjectType) -> BikeWriteStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        switch store.authorizationStatus(for: type) {
        case .sharingAuthorized: return .authorized
        case .sharingDenied: return .denied
        default: return .notDetermined
        }
    }

    var workoutWriteStatus: BikeWriteStatus { status(HKObjectType.workoutType()) }
    var heartRateWriteStatus: BikeWriteStatus { status(heartRate) }

    func requestCoreAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw BikeImportError.healthUnavailable }
        try await store.requestAuthorization(toShare: coreShareTypes, read: [])
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

    func save(_ plan: BikeWorkoutPlan) async throws -> [String] {
        var skipped: [String] = []
        func allowed(_ type: HKQuantityType, _ label: String) -> Bool {
            if status(type) == .authorized { return true }
            skipped.append(label)
            return false
        }
        let withEnergy = plan.totalKcal > 0 && allowed(energy, "active energy")
        let withDistance = plan.totalMeters > 0 && allowed(distance, "cycling distance")
        let withPower = allowed(power, "cycling power")
        let withCadence = allowed(cadence, "cycling cadence")
        let withHR = plan.writeHeartRate && status(heartRate) == .authorized

        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .indoor
        let device = HKDevice(name: "Peloton Pi", manufacturer: nil, model: nil, hardwareVersion: nil,
                              firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: device)

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
                if withEnergy, plan.kcalPerBucket[i] > 0 { samples.append(q(energy, .kilocalorie(), plan.kcalPerBucket[i])) }
                if withDistance, plan.metersPerBucket[i] > 0 { samples.append(q(distance, .meter(), plan.metersPerBucket[i])) }
                if withPower { samples.append(q(power, .watt(), b.power)) }
                if withCadence { samples.append(q(cadence, HKUnit.count().unitDivided(by: .minute()), b.cadence)) }
                if withHR, let hr = b.heartRate { samples.append(q(heartRate, HKUnit.count().unitDivided(by: .minute()), hr)) }
            }
            try await builder.addSamples(samples)
            try await builder.endCollection(at: plan.end)
            guard try await builder.finishWorkout() != nil else { throw HKError(.errorDatabaseInaccessible) }
        } catch {
            builder.discardWorkout()
            throw error
        }
        return skipped
    }
}
