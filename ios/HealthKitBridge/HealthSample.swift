import Foundation

// MARK: - HealthSample

/// Codable struct matching the HTTP POST payload schema for a single HealthKit sample.
struct HealthSample: Codable, Equatable {
    let metricType: String
    let value: Double
    let unit: String
    let sourceDevice: String
    let startedAt: Date
    let endedAt: Date
    let metadata: [String: AnyCodableValue]?

    enum CodingKeys: String, CodingKey {
        case metricType = "metric_type"
        case value
        case unit
        case sourceDevice = "source_device"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case metadata
    }
}

// MARK: - SampleBatch

struct SampleBatch: Codable {
    let samples: [HealthSample]
}

// MARK: - AnyCodableValue
// A heterogeneous JSON value type for metadata fields.

enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else {
            throw DecodingError.typeMismatch(
                AnyCodableValue.self,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Unsupported type")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .bool(let v):   try container.encode(v)
        case .null:          try container.encodeNil()
        }
    }

    /// Convenience initializer from Any (used when building metadata dicts from HK metadata).
    static func from(_ value: Any) -> AnyCodableValue? {
        switch value {
        case let v as String:  return .string(v)
        case let v as Double:  return .double(v)
        case let v as Float:   return .double(Double(v))
        case let v as Int:     return .int(v)
        case let v as Bool:    return .bool(v)
        default:               return .string("\(value)")
        }
    }
}
