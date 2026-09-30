#if H4A_SHEETS
// Compiled only with H4A_SHEETS (off in Release by default; see docs/sheets-build-gate.md).
import Foundation
import HealthKit
import os

// Builds the Google Sheets destination's rows on device. Daily totals come from
// HKStatisticsCollectionQuery, which dedupes overlapping sources (iPhone + Watch steps)
// the same way the Health app does; sleep uses SleepMath's union for the same reason.

/// The person's preferred units, fixed when their sheet is created so a column never
/// changes meaning half way down.
struct SheetUnits: Codable, Equatable {
    var miles: Bool
    var pounds: Bool

    var distanceUnit: HKUnit { miles ? .mile() : .meterUnit(with: .kilo) }
    var massUnit: HKUnit { pounds ? .pound() : .gramUnit(with: .kilo) }
    var distanceLabel: String { miles ? "mi" : "km" }
    var massLabel: String { pounds ? "lb" : "kg" }

    static func preferred(from store: HKHealthStore) async -> SheetUnits {
        let distance = HKQuantityType(.distanceWalkingRunning)
        let mass = HKQuantityType(.bodyMass)
        let prefs = (try? await store.preferredUnits(for: [distance, mass])) ?? [:]
        return SheetUnits(miles: prefs[distance] == .mile(), pounds: prefs[mass] == .pound())
    }
}

enum SheetLayout {
    static let dailyTab = SheetTabs.daily
    static let workoutsTab = SheetTabs.workouts
    static let aboutTab = SheetTabs.about

    static func dailyHeader(_ u: SheetUnits) -> [String] {
        ["Date", "Steps", "Distance (\(u.distanceLabel))", "Active energy (kcal)", "Exercise (min)",
         "Stand hours", "Flights climbed", "Resting HR (bpm)", "Avg HR (bpm)", "HRV (ms)",
         "Sleep (h)", "In bed (h)", "Workouts", "Workout time (min)",
         "Weight (\(u.massLabel))", "VO2 max (mL/kg/min)"]
    }

    static func workoutsHeader(_ u: SheetUnits) -> [String] {
        ["Date", "Start", "Type", "Duration (min)", "Active energy (kcal)",
         "Distance (\(u.distanceLabel))", "Source", "Workout ID"]
    }

    /// A column dictionary for whoever reads the sheet, person or AI connector.
    static func about(_ u: SheetUnits) -> [[String]] {
        [["Column", "Meaning"],
         ["Daily tab", "One row per day in your device's time zone, from the Health app. The last few days are refreshed on every sync as late data arrives."],
         ["Steps / Distance / Active energy / Exercise / Flights", "Totals for the day, with overlapping devices counted once."],
         ["Stand hours", "Hours in the day with a stand recorded (Apple Watch)."],
         ["Resting HR / Avg HR / HRV", "Averages of the day's readings. HRV is SDNN in milliseconds."],
         ["Sleep / In bed", "The night ending on this date (noon to noon), with overlapping devices counted once."],
         ["Weight / VO2 max", "Most recent reading that day."],
         ["Blank cell", "No data that day. Blank never means zero."],
         ["Workouts tab", "One row per workout. Workout ID is how health4ai avoids duplicates; please leave it."],
         ["Units", "Distance in \(u.distanceLabel), weight in \(u.massLabel), energy in kcal."],
         ["Rebuilds", "After some updates health4ai rebuilds the Daily tab from your Health data: it rewrites the data rows in columns A to P, so anything typed into them is replaced. Keep your own notes in another tab or to the right of column P. The Workouts tab is never cleared; workouts are only added, and their type names tidied."],
         ["Privacy", "Written straight from your device to your Google Drive. It never passes through a health4ai server."]]
    }
}

final class DailySummaryBuilder {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "SheetsSink")
    /// Every type this builder queries. HealthKit THROWS "Authorization not determined" for a
    /// type the app never asked about (it only hides a DENIED read as empty), so the Sheets
    /// connect flow requests this set on top of the chosen scope, and SheetsSink checks it
    /// before a pass. Stand hours are in neither scope, which is how build 54 failed.
    static let readTypes: Set<HKSampleType> = [
        HKQuantityType(.stepCount), HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned), HKQuantityType(.appleExerciseTime),
        HKQuantityType(.flightsClimbed), HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRate), HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.bodyMass), HKQuantityType(.vo2Max),
        HKCategoryType(.appleStandHour), HKCategoryType(.sleepAnalysis),
        HKWorkoutType.workoutType()
    ]

    private let store: HKHealthStore
    private let calendar: Calendar

    init(store: HKHealthStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    /// Earliest day worth sweeping on a first connect: the oldest step, heart rate, sleep or
    /// workout sample, capped at ten years back so a first sync always finishes. THROWS if any type's
    /// query fails (locked device, cancelled background task): starting from the other types'
    /// oldest day would silently leave the earlier history out of the sheet.
    func earliestDataDay(now: Date = Date()) async throws -> Date {
        let today = calendar.startOfDay(for: now)
        let floor = calendar.date(byAdding: .year, value: -10, to: today)!
        let types: [HKSampleType] = [HKQuantityType(.stepCount), HKQuantityType(.heartRate),
                                     HKCategoryType(.sleepAnalysis), HKWorkoutType.workoutType()]
        var results: [SweepStart.TypeResult] = []
        for type in types {
            let d = HKSampleQueryDescriptor(predicates: [.sample(type: type)],
                                            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)], limit: 1)
            do {
                let first = try await d.result(for: store).first
                Self.logger.info("earliest \(type.identifier, privacy: .public): \(first?.startDate.description ?? "none", privacy: .private)")
                results.append(.success(first?.startDate))
            } catch {
                Self.logger.error("earliest \(type.identifier, privacy: .public) query failed: \(error.localizedDescription, privacy: .private)")
                results.append(.failure(error))
            }
        }
        return try SweepStart.resolve(results, today: today, floor: floor, calendar: calendar)
    }

    /// One Daily row per day in [start, end], each beginning with its date key.
    func dailyRows(from start: Date, through end: Date, units: SheetUnits) async throws -> [[String]] {
        let days = DayKey.days(from: start, through: end, calendar: calendar)
        guard let first = days.first, let last = days.last else { return [] }
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: last)!

        async let steps = collection(.stepCount, .cumulativeSum, first, rangeEnd)
        async let distance = collection(.distanceWalkingRunning, .cumulativeSum, first, rangeEnd)
        async let energy = collection(.activeEnergyBurned, .cumulativeSum, first, rangeEnd)
        async let exercise = collection(.appleExerciseTime, .cumulativeSum, first, rangeEnd)
        async let flights = collection(.flightsClimbed, .cumulativeSum, first, rangeEnd)
        async let resting = collection(.restingHeartRate, .discreteAverage, first, rangeEnd)
        async let heart = collection(.heartRate, .discreteAverage, first, rangeEnd)
        async let hrv = collection(.heartRateVariabilitySDNN, .discreteAverage, first, rangeEnd)
        async let weight = collection(.bodyMass, .mostRecent, first, rangeEnd)
        async let vo2 = collection(.vo2Max, .mostRecent, first, rangeEnd)
        async let stand = standHours(first, rangeEnd)
        async let sleep = sleepByDay(days)
        async let workouts = workouts(from: first, to: rangeEnd)

        let (s, di, en, ex, fl, rhr, hr, hv, wt, vo) =
            try await (steps, distance, energy, exercise, flights, resting, heart, hrv, weight, vo2)
        let (st, sl, wk) = try await (stand, sleep, workouts)

        let bpm = HKUnit.count().unitDivided(by: .minute())
        let vo2Unit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        var workoutsByDay: [String: (count: Int, minutes: Double)] = [:]
        for w in wk {
            let key = DayKey.string(for: w.startDate, calendar: calendar)
            let prev = workoutsByDay[key] ?? (0, 0)
            workoutsByDay[key] = (prev.count + 1, prev.minutes + w.duration / 60)
        }

        return days.map { day in
            let key = DayKey.string(for: day, calendar: calendar)
            let workoutsToday = workoutsByDay[key]
            return [
                key,
                SheetCell.number(s.statistics(for: day)?.sumQuantity()?.doubleValue(for: .count()), decimals: 0),
                SheetCell.number(di.statistics(for: day)?.sumQuantity()?.doubleValue(for: units.distanceUnit), decimals: 2),
                SheetCell.number(en.statistics(for: day)?.sumQuantity()?.doubleValue(for: .kilocalorie()), decimals: 0),
                SheetCell.number(ex.statistics(for: day)?.sumQuantity()?.doubleValue(for: .minute()), decimals: 0),
                SheetCell.number(st[key].map(Double.init), decimals: 0),
                SheetCell.number(fl.statistics(for: day)?.sumQuantity()?.doubleValue(for: .count()), decimals: 0),
                SheetCell.number(rhr.statistics(for: day)?.averageQuantity()?.doubleValue(for: bpm), decimals: 0),
                SheetCell.number(hr.statistics(for: day)?.averageQuantity()?.doubleValue(for: bpm), decimals: 0),
                SheetCell.number(hv.statistics(for: day)?.averageQuantity()?.doubleValue(for: .secondUnit(with: .milli)), decimals: 0),
                SheetCell.number(sl[key].map { $0.asleep / 3600 }, decimals: 2),
                SheetCell.number(sl[key].map { $0.inBed / 3600 }, decimals: 2),
                SheetCell.number(workoutsToday.map { Double($0.count) }, decimals: 0),
                SheetCell.number(workoutsToday?.minutes, decimals: 0),
                SheetCell.number(wt.statistics(for: day)?.mostRecentQuantity()?.doubleValue(for: units.massUnit), decimals: 1),
                SheetCell.number(vo.statistics(for: day)?.mostRecentQuantity()?.doubleValue(for: vo2Unit), decimals: 1),
            ]
        }
    }

    /// Workouts tab rows for workouts that started in [start, end).
    func workoutRows(from start: Date, to end: Date, units: SheetUnits) async throws -> [[String]] {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        // Derived from the canonical double-counted list so a new distance type added there is
        // picked up here too, instead of a second hand-kept copy drifting (Reviewboard C).
        let distanceTypes: [HKQuantityType] = HealthKitManager.doubleCountedActivityIdentifiers
            .filter { $0.hasPrefix("HKQuantityTypeIdentifierDistance") }
            .sorted()
            .map { HKQuantityType(HKQuantityTypeIdentifier(rawValue: $0)) }
        return try await workouts(from: start, to: end).map { w in
            let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            let distance = distanceTypes.lazy
                .compactMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: units.distanceUnit) }
                .first
            return [DayKey.string(for: w.startDate, calendar: calendar), time.string(from: w.startDate),
                    SheetCell.text(WorkoutName.display(fromIdentifier: w.workoutActivityType.name)), SheetCell.number(w.duration / 60, decimals: 0),
                    SheetCell.number(energy, decimals: 0), SheetCell.number(distance, decimals: 2),
                    SheetCell.text(w.sourceRevision.source.name), w.uuid.uuidString]
        }
    }

    // MARK: Queries

    private func collection(_ id: HKQuantityTypeIdentifier, _ options: HKStatisticsOptions,
                            _ start: Date, _ end: Date) async throws -> HKStatisticsCollection {
        assert(Self.readTypes.contains(HKQuantityType(id)), "\(id.rawValue) missing from readTypes")
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate),
            options: options,
            anchorDate: calendar.startOfDay(for: start),
            intervalComponents: DateComponents(day: 1))
        return try await descriptor.result(for: store)
    }

    private func workouts(from start: Date, to end: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let d = HKSampleQueryDescriptor(predicates: [.workout(predicate)],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        return try await d.result(for: store)
    }

    private func standHours(_ start: Date, _ end: Date) async throws -> [String: Int] {
        assert(Self.readTypes.contains(HKCategoryType(.appleStandHour)), "appleStandHour missing from readTypes")
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.appleStandHour), predicate: predicate)],
                                        sortDescriptors: [])
        var out: [String: Int] = [:]
        for s in try await d.result(for: store) where s.value == HKCategoryValueAppleStandHour.stood.rawValue {
            out[DayKey.string(for: s.startDate, calendar: calendar), default: 0] += 1
        }
        return out
    }

    private func sleepByDay(_ days: [Date]) async throws -> [String: (asleep: TimeInterval, inBed: TimeInterval)] {
        guard let first = days.first, let last = days.last else { return [:] }
        let span = DateInterval(start: SleepMath.window(for: first, calendar: calendar).start,
                                end: SleepMath.window(for: last, calendar: calendar).end)
        let predicate = HKQuery.predicateForSamples(withStart: span.start, end: span.end)
        let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                                        sortDescriptors: [])
        let samples = try await d.result(for: store)
        let asleepValues = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let asleep = samples.filter { asleepValues.contains($0.value) }
            .map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) }
        // "In bed" covers asleep time too: someone whose tracker records only stages still
        // has an in-bed figure rather than a blank.
        let inBed = asleep + samples.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }
            .map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) }

        var out: [String: (asleep: TimeInterval, inBed: TimeInterval)] = [:]
        for day in days {
            let window = SleepMath.window(for: day, calendar: calendar)
            let a = SleepMath.unionDuration(asleep, clippedTo: window)
            let b = SleepMath.unionDuration(inBed, clippedTo: window)
            if a > 0 || b > 0 { out[DayKey.string(for: day, calendar: calendar)] = (a, b) }
        }
        return out
    }
}
#endif
