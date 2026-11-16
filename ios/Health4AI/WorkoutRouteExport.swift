import Foundation

@MainActor
enum WorkoutRouteExport {
    static func run(workoutID: UUID, routes: [WorkoutRouteDescriptor], client: WorkoutDetailClient,
                    validate: () throws -> Void,
                    read: (WorkoutRouteDescriptor) async throws -> WorkoutRouteObservation) async throws -> WorkoutRouteSummary {
        try validate()
        guard routes.count <= 32, Set(routes.map(\.routeUUID)).count == routes.count,
              routes.allSatisfy({ $0.sourceCount >= 0 && $0.sourceCount <= 100_000 }),
              routes.reduce(0, { $0 + $1.sourceCount }) <= 100_000 else { throw WorkoutDetailError.limit }
        let capability = try await client.send(WorkoutDetailRequest(operation: "capabilities"))
        try validate()
        guard capability.capabilities?.contains("workout_routes_v1") == true else {
            throw WorkoutDetailError.unavailable
        }
        let revision = UUID().uuidString.lowercased(), workout = workoutID.uuidString.lowercased()
        let begun = try await client.send(WorkoutDetailRequest(operation: "begin", workoutUUID: workout,
            exportUUID: revision, routes: routes))
        try validate()
        guard begun.exportUUID == revision, begun.complete == false else { throw WorkoutDetailError.invalidResponse }
        var total = 0
        var invalid: [WorkoutRouteInvalidCount] = []
        for route in routes {
            try validate()
            let observation = try await read(route)
            try validate()
            guard observation.invalidCount >= 0,
                  observation.points.count + observation.invalidCount == route.sourceCount,
                  Set(observation.points.map(\.pointIndex)).count == observation.points.count,
                  observation.points.allSatisfy({ $0.routeUUID == route.routeUUID &&
                      $0.pointIndex >= 0 && $0.pointIndex < route.sourceCount }) else {
                throw WorkoutDetailError.healthChanged
            }
            invalid.append(WorkoutRouteInvalidCount(routeUUID: route.routeUUID, invalidCount: observation.invalidCount))
            var remaining = observation.points[...]
            while !remaining.isEmpty {
                var size = min(500, remaining.count)
                var request: WorkoutDetailRequest
                while true {
                    request = WorkoutDetailRequest(operation: "page", workoutUUID: workout,
                        exportUUID: revision, points: Array(remaining.prefix(size)))
                    do { _ = try request.data(); break }
                    catch WorkoutDetailError.limit {
                        guard size > 1 else { throw WorkoutDetailError.limit }; size /= 2
                    }
                }
                let saved = try await client.send(request)
                try validate()
                total += size
                guard saved.observedCount == total else { throw WorkoutDetailError.invalidResponse }
                remaining = remaining.dropFirst(size)
            }
        }
        let finished = try await client.send(WorkoutDetailRequest(operation: "finalize", workoutUUID: workout,
            exportUUID: revision, invalidCounts: invalid))
        try validate()
        guard finished.exportUUID == revision, finished.complete == true, finished.coverage == "observed_only",
              finished.observedCount == total,
              finished.invalidCounts?.sorted(by: { $0.routeUUID < $1.routeUUID }) ==
                invalid.sorted(by: { $0.routeUUID < $1.routeUUID }) else { throw WorkoutDetailError.invalidResponse }
        return WorkoutRouteSummary(valid: total, invalid: invalid.reduce(0, { $0 + $1.invalidCount }))
    }
}
