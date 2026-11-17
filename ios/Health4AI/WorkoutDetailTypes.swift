import Foundation

struct WorkoutDetailIdentity: Equatable {
    let endpoint: String
    let userID: String
    let connectionRevision: Int
    let signOutGeneration: Int

    var consentKey: String { "hkb.workoutDetails.consent." + endpoint + "|" + userID }

    var detailURL: URL? {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasSuffix("/functions/v1/healthkit-ingest") else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("workout-details")
    }
}

struct WorkoutDetailSample: Codable, Equatable {
    enum CodingKeys: String, CodingKey {
        case sampleUUID = "sample_uuid"
        case metricType = "metric_type"
        case value
        case unit
        case sourceDevice = "source_device"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
    let sampleUUID: String
    let metricType: String
    let value: Double
    let unit: String
    let sourceDevice: String
    let startedAt: String
    let endedAt: String
}

struct WorkoutDetailRequest: Encodable {
    enum CodingKeys: String, CodingKey {
        case operation
        case workoutUUID = "workout_uuid"
        case exportUUID = "export_uuid"
        case queryTypes = "query_types"
        case samples
        case observedCount = "observed_count"
        case routes
        case points
        case invalidCounts = "invalid_counts"
    }
    let operation: String
    var workoutUUID: String? = nil
    var exportUUID: String? = nil
    var queryTypes: [String]? = nil
    var samples: [WorkoutDetailSample]? = nil
    var observedCount: Int? = nil
    var routes: [WorkoutRouteDescriptor]? = nil
    var points: [WorkoutRoutePoint]? = nil
    var invalidCounts: [WorkoutRouteInvalidCount]? = nil

    func data() throws -> Data {
        let data = try JSONEncoder().encode(self)
        // Leave room for the server's JSONB representation (including spacing).
        guard data.count <= 200 * 1024 else { throw WorkoutDetailError.limit }
        return data
    }
}

struct WorkoutDetailResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case capabilities
        case exportUUID = "export_uuid"
        case complete
        case observedCount = "observed_count"
        case coverage
        case deletedExports = "deleted_exports"
        case invalidCounts = "invalid_counts"
    }
    var capabilities: [String]?
    var exportUUID: String?
    var complete: Bool?
    var observedCount: Int?
    var coverage: String?
    var deletedExports: Int?
    var invalidCounts: [WorkoutRouteInvalidCount]?
}

enum WorkoutDetailError: LocalizedError {
    case changed, unavailable, invalidResponse, limit, healthChanged, unsupported, server(Int)

    var errorDescription: String? {
        switch self {
        case .changed: return "Export stopped because consent, account, destination or Health scope changed."
        case .unavailable: return "This server has not enabled workout detail export. Ask its owner to install and enable " +
            "the optional feature."
        case .invalidResponse: return "The server did not confirm the result. No completion is claimed."
        case .limit: return "This export exceeds the supported request or sample limit. No completed snapshot was confirmed."
        case .healthChanged: return "Health data changed during this export. Start a new export; this attempt was not finalized."
        case .unsupported: return "A Health sample could not be represented safely. This attempt was not finalized."
        case .server(let status): return "The server rejected this operation (HTTP \(status)). If storage is full, delete older " +
            "detail exports before trying again."
        }
    }
}

struct WorkoutDetailDeletion: Identifiable {
    let id = UUID()
    enum Target { case all, workout(UUID) }
    let identity: WorkoutDetailIdentity
    let target: Target
    let routes: Bool

    func request(current: WorkoutDetailIdentity?) throws -> WorkoutDetailRequest {
        guard current == identity else { throw WorkoutDetailError.changed }
        switch target {
        case .all: return WorkoutDetailRequest(operation: "delete_all")
        case .workout(let id): return WorkoutDetailRequest(operation: "delete", workoutUUID: id.uuidString.lowercased())
        }
    }
}
