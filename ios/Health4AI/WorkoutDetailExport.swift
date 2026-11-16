import HealthKit

@MainActor
enum WorkoutDetailExport {
    typealias ReadPage = (HKQuantityType, HKQueryAnchor?) async throws -> WorkoutDetailHealthPage

    static func run(workoutID: UUID, types: [HKQuantityType], client: WorkoutDetailClient,
                    validate: () throws -> Void, read: ReadPage) async throws -> Int {
        try validate()
        guard !types.isEmpty else { throw WorkoutDetailError.unsupported }
        let capability = try await client.send(WorkoutDetailRequest(operation: "capabilities"))
        try validate()
        guard capability.capabilities?.contains("workout_details_v1") == true else {
            throw WorkoutDetailError.unavailable
        }
        let revision = UUID().uuidString.lowercased()
        let workout = workoutID.uuidString.lowercased()
        let begin = try await client.send(WorkoutDetailRequest(operation: "begin", workoutUUID: workout,
            exportUUID: revision, queryTypes: types.map(\.identifier)))
        try validate()
        guard begin.exportUUID == revision, begin.complete == false else {
            throw WorkoutDetailError.invalidResponse
        }
        var observed: [String: WorkoutDetailSample] = [:]
        for type in types {
            var anchor: HKQueryAnchor?
            var pages = 0
            while true {
                try validate()
                let page = try await read(type, anchor)
                try validate()
                pages += 1
                guard pages <= 201, page.samples.count <= 500,
                      !page.hasMore || (!page.samples.isEmpty && page.anchor != nil) else {
                    throw WorkoutDetailError.limit
                }
                for sample in page.samples {
                    guard sample.metricType == type.identifier else { throw WorkoutDetailError.unsupported }
                    if let old = observed[sample.sampleUUID], old != sample {
                        throw WorkoutDetailError.healthChanged
                    }
                    observed[sample.sampleUUID] = sample
                }
                guard observed.count <= 100_000 else { throw WorkoutDetailError.limit }
                var remaining = page.samples[...]
                while !remaining.isEmpty {
                    var size = remaining.count
                    var body: WorkoutDetailRequest
                    while true {
                        body = WorkoutDetailRequest(operation: "page", workoutUUID: workout,
                            exportUUID: revision, samples: Array(remaining.prefix(size)))
                        do { _ = try body.data(); break }
                        catch WorkoutDetailError.limit {
                            guard size > 1 else { throw WorkoutDetailError.limit }
                            size /= 2
                        }
                    }
                    let saved = try await client.send(body)
                    try validate()
                    guard let count = saved.observedCount, count >= 0, count <= observed.count else {
                        throw WorkoutDetailError.invalidResponse
                    }
                    remaining = remaining.dropFirst(size)
                }
                if !page.hasMore { break }
                anchor = page.anchor
            }
        }
        try validate()
        let finished = try await client.send(WorkoutDetailRequest(operation: "finalize", workoutUUID: workout,
            exportUUID: revision, observedCount: observed.count))
        try validate()
        guard finished.exportUUID == revision, finished.complete == true,
              finished.observedCount == observed.count, finished.coverage == "observed_only" else {
            throw WorkoutDetailError.invalidResponse
        }
        return observed.count
    }
}
