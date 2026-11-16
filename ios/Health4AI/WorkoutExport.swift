import Foundation
import HealthKit
import os

/// Additional workout context within the existing ingest metadata limit (4 KiB).
/// Never treats a time-overlapping metric as an exact workout association.
enum WorkoutExport {
    static let metadataLimit = 4 * 1024

    static func metadata(
        for workout: HKWorkout, preserving original: [String: AnyCodableValue]
    ) -> [String: AnyCodableValue] {
        var meta = original
        meta["workout_uuid"] = .string(workout.uuid.uuidString)
        guard let events = workout.workoutEvents else {
            meta["workout_events"] = .null
            meta["workout_events_total"] = .null
            meta["workout_events_truncated"] = .null
            return fits(meta) ? meta : insufficientSpace(original)
        }
        meta["workout_events"] = .array([])
        meta["workout_events_total"] = .int(events.count)
        // Reserve the longer JSON boolean spelling before budgeting entries.
        meta["workout_events_truncated"] = .bool(false)
        guard fits(meta) else { return insufficientSpace(original) }

        var exported: [AnyCodableValue] = []
        for event in events {
            let next = exported + [encode(event)]
            meta["workout_events"] = .array(next)
            if !fits(meta) { break }
            exported = next
        }
        meta["workout_events"] = .array(exported)
        meta["workout_events_truncated"] = .bool(exported.count < events.count)
        return meta
    }

    private static func fits(_ meta: [String: AnyCodableValue]) -> Bool {
        guard let data = try? JSONEncoder().encode(meta) else { return false }
        // Ingest parses JSON then measures JSON.stringify. JS can expand 1e+20
        // to 21 digits. Reserve 32 bytes per number, more than a finite JS
        // Number's longest decimal spelling, rather than trusting Swift's size.
        let reserve = meta.values.reduce(0) { $0 + numericReserve($1) }
        return data.count + reserve <= metadataLimit
    }

    private static func numericReserve(_ value: AnyCodableValue) -> Int {
        switch value {
        case .double, .int: return 32
        case .array(let values): return values.reduce(0) { $0 + numericReserve($1) }
        case .object(let values): return values.values.reduce(0) { $0 + numericReserve($1) }
        default: return 0
        }
    }

    private static func insufficientSpace(
        _ original: [String: AnyCodableValue]
    ) -> [String: AnyCodableValue] {
        Logger(subsystem: "com.jglittell.health4ai", category: "WorkoutExport")
            .warning("Workout event enrichment omitted: existing metadata leaves no space within ingest limit")
        // No completeness fields means unknown, just like exports from older builds.
        // Preserve the original record; enrichment must not make a valid batch fail.
        return original
    }

    private static func encode(_ event: HKWorkoutEvent) -> AnyCodableValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .object([
            "type": .string(name(event.type)),
            "type_raw": .int(event.type.rawValue),
            "started_at": .string(formatter.string(from: event.dateInterval.start)),
            "ended_at": .string(formatter.string(from: event.dateInterval.end)),
            "duration_seconds": .double(event.dateInterval.duration)
        ])
    }

    static func name(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: return "pause"
        case .resume: return "resume"
        case .lap: return "lap"
        case .marker: return "marker"
        case .motionPaused: return "motion_paused"
        case .motionResumed: return "motion_resumed"
        case .segment: return "segment"
        case .pauseOrResumeRequest: return "pause_or_resume_request"
        @unknown default: return "unknown"
        }
    }
}
