import HealthKit

struct WorkoutDetailHealthPage {
    let samples: [WorkoutDetailSample]
    let anchor: HKQueryAnchor?
    let hasMore: Bool
}

enum WorkoutDetailHealthReader {
    static let identifiers: [HKQuantityTypeIdentifier] = [
        .heartRate, .runningSpeed, .runningPower, .runningStrideLength,
        .runningVerticalOscillation, .runningGroundContactTime, .stepCount
    ]

    static func queryTypes(scope: HealthKitManager.DataScope) -> [HKQuantityType] {
        let permitted = HealthKitManager.sampleTypes(for: scope)
        return identifiers.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            .filter { permitted.contains($0) }
    }

    static func workouts() async throws -> [HKWorkout] {
        try await WorkoutHealthQuery<[HKWorkout]>().run { complete in
            HKSampleQuery(sampleType: .workoutType(),
                                      predicate: HKQuery.predicateForWorkouts(with: .running), limit: 30,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                        ascending: false)]) { _, samples, error in
                if let error { complete(.failure(error)) }
                else { complete(.success((samples ?? []).compactMap { $0 as? HKWorkout })) }
            }
        }
    }

    static func page(workout: HKWorkout, type: HKQuantityType,
                     anchor: HKQueryAnchor?) async throws -> WorkoutDetailHealthPage {
        try await WorkoutHealthQuery<WorkoutDetailHealthPage>().run { complete in
            HKAnchoredObjectQuery(type: type,
                predicate: HKQuery.predicateForObjects(from: workout), anchor: anchor, limit: 500) {
                _, samples, deleted, next, error in
                if let error { complete(.failure(error)); return }
                do {
                    guard (deleted ?? []).isEmpty else { throw WorkoutDetailError.healthChanged }
                    let raw = samples ?? []
                    guard raw.count <= 500, let next else { throw WorkoutDetailError.invalidResponse }
                    let converted = try raw.map { sample -> WorkoutDetailSample in
                        guard let quantity = sample as? HKQuantitySample else { throw WorkoutDetailError.unsupported }
                        return try convert(quantity)
                    }
                    complete(.success(WorkoutDetailHealthPage(samples: converted, anchor: next,
                                                              hasMore: raw.count == 500)))
                } catch { complete(.failure(error)) }
            }
        }
    }

    static func convert(_ sample: HKQuantitySample) throws -> WorkoutDetailSample {
        let identifier = sample.quantityType.identifier
        guard identifiers.contains(where: { $0.rawValue == identifier }),
              let unit = HealthKitManager.unitMap[identifier], sample.quantity.is(compatibleWith: unit) else {
            throw WorkoutDetailError.unsupported
        }
        let value = sample.quantity.doubleValue(for: unit)
        let source = sample.device?.name ?? sample.sourceRevision.source.name
        guard value.isFinite, source.count <= 256, sample.endDate >= sample.startDate else {
            throw WorkoutDetailError.unsupported
        }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return WorkoutDetailSample(sampleUUID: sample.uuid.uuidString.lowercased(), metricType: identifier,
            value: value, unit: unit.unitString, sourceDevice: source,
            startedAt: format.string(from: sample.startDate), endedAt: format.string(from: sample.endDate))
    }
}
