#if H4A_SHEETS
// Compiled only with H4A_SHEETS (on in Debug and Release since 1.0.1; see docs/sheets-build-gate.md).
import CryptoKit
import Foundation
import Security

// Pure logic for the Google Sheets destination: no HealthKit, no network, no UI, so every
// function here compiles into the off-device test harness (`scripts/test_sheets_logic.sh`).

// MARK: - PKCE

/// OAuth PKCE (RFC 7636) for Google sign-in. An iOS OAuth client has no client secret, so
/// the verifier/challenge pair is the only thing proving the code exchange came from the
/// app that started the sign-in.
enum PKCE {
    /// 32 random bytes, base64url: 43 characters, inside RFC 7636's 43-128 range.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64url(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Sleep

enum SleepMath {
    /// The window whose sleep counts toward `day`: noon the day before to noon on `day`, in
    /// the given calendar's time zone. A night belongs to the date you wake up on, which is
    /// how the Health app itself labels sleep.
    static func window(for day: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start)!
        let prevNoon = calendar.date(byAdding: .day, value: -1, to: noon)!
        return DateInterval(start: prevNoon, end: noon)
    }

    /// Total time covered by the union of `intervals`, clipped to `window`.
    ///
    /// Union, not sum: a Watch, a ring and the phone all recording the same night must count
    /// that night once. Summing overlapping sources is the exact double count the
    /// merged-hours fix removed from steps and energy (register D361).
    static func unionDuration(_ intervals: [DateInterval], clippedTo window: DateInterval) -> TimeInterval {
        let clipped = intervals.compactMap { $0.intersection(with: window) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in clipped {
            if let cur = current, interval.start <= cur.end {
                current = DateInterval(start: cur.start, end: max(cur.end, interval.end))
            } else {
                if let cur = current { total += cur.duration }
                current = interval
            }
        }
        if let cur = current { total += cur.duration }
        return total
    }

    /// The night a sleep record belongs to: the date of the noon-to-noon window it starts in
    /// (`window(for:)`), so the Sleep stages tab and the Daily tab's Sleep column agree.
    static func night(for start: Date, calendar: Calendar) -> String {
        DayKey.string(for: calendar.date(byAdding: .hour, value: 12, to: start)!, calendar: calendar)
    }
}

// MARK: - Sleep stages tab

enum SleepStageLayout {
    static let header = ["Night", "Stage", "Start", "End", "Duration (min)", "Source", "Record ID"]
    /// Column of the record ID, which is how a pass avoids writing a record twice.
    static let idColumn = "G"
    static let idIndex = 6

    /// HKCategoryValueSleepAnalysis raw values (stable since iOS 16), named the way the
    /// Health app names them. Before iOS 16 a Watch recorded only "asleep", which has no
    /// stage: said so, rather than left looking like a gap.
    static func stage(rawValue: Int) -> String {
        switch rawValue {
        case 0: return "In bed"
        case 1: return "Asleep (no stage)"
        case 2: return "Awake"
        case 3: return "Core"
        case 4: return "Deep"
        case 5: return "REM"
        default: return "Other"
        }
    }

    /// The first sheet row (1-based, header is row 1) whose Night is on or after `key`. A
    /// pass only needs the record IDs from there down: anything it re-reads from HealthKit
    /// starts on or after that night. Rows are appended roughly in night order, but a late
    /// record can land below a newer night; it is still below this row, so it is still seen.
    /// Text a person typed into the column is skipped.
    static func firstRow(nights: [String], onOrAfter key: String) -> Int? {
        for (i, raw) in nights.enumerated() {
            let night = raw.trimmingCharacters(in: .whitespaces)
            if DateKeys.isKey(night), night >= key { return i + 2 }
        }
        return nil
    }
}

// MARK: - Day keys

enum DayKey {
    /// "yyyy-MM-dd" in the given calendar's time zone. Sheets reads this as a date when
    /// written with USER_ENTERED, and it sorts correctly as text, which the upsert relies on.
    static func string(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The day key for a Sheets date serial number (days since 1899-12-30, the Lotus/Excel
    /// epoch Sheets uses). The Date column is written USER_ENTERED, so Sheets stores a real
    /// date and DISPLAYS it in the sheet's locale ("9/28/2026"); comparing that displayed text
    /// with our "2026-09-28" keys never matches and every sync would append duplicates.
    /// Reading the column UNFORMATTED returns this serial instead, which is locale-proof.
    static func string(fromSheetsSerial serial: Double) -> String? {
        guard serial.isFinite, serial >= 1 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let epoch = utc.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        guard let day = utc.date(byAdding: .day, value: Int(serial.rounded(.down)), to: epoch) else { return nil }
        return string(for: day, calendar: utc)
    }

    /// Every local day from `start` through `end`, inclusive, as start-of-day dates.
    /// Steps by calendar day, not 86,400 seconds, so a DST change never skips or repeats a day.
    static func days(from start: Date, through end: Date, calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last {
            out.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }
}

// MARK: - Upsert plan

/// Where each freshly built Daily row goes: overwrite the row that already holds its date,
/// or append. `existingDates` is column A from row 2 down, exactly as the sheet returned it.
struct UpsertPlan: Equatable {
    /// Sheet row number (1-based, header is row 1) and the row's values.
    var updates: [(row: Int, values: [String])]
    var appends: [[String]]

    static func == (a: UpsertPlan, b: UpsertPlan) -> Bool {
        a.updates.map(\.row) == b.updates.map(\.row)
            && a.updates.map(\.values) == b.updates.map(\.values)
            && a.appends == b.appends
    }

    /// `rows` must each start with their date key. Dates already in the sheet are updated
    /// in place; new ones are appended in ascending date order. A date the person typed over
    /// or reformatted in the sheet is not recognised and gets a fresh row: duplicating one
    /// day is recoverable, silently overwriting someone's edits is not.
    static func make(existingDates: [String], rows: [[String]]) -> UpsertPlan {
        var rowForDate: [String: Int] = [:]
        for (i, raw) in existingDates.enumerated() {
            let key = raw.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, rowForDate[key] == nil { rowForDate[key] = i + 2 }
        }
        var updates: [(row: Int, values: [String])] = []
        var appends: [[String]] = []
        for row in rows.sorted(by: { ($0.first ?? "") < ($1.first ?? "") }) {
            guard let key = row.first else { continue }
            if let existing = rowForDate[key] {
                updates.append((existing, row))
            } else {
                appends.append(row)
            }
        }
        return UpsertPlan(updates: updates, appends: appends)
    }
}

// MARK: - Cell formatting

enum SheetCell {
    /// Text from outside this app (a workout's source-app name is whatever that app calls
    /// itself). Cells are written USER_ENTERED, so a name like `=IMPORTXML("http://…")` would
    /// become a live formula in the person's sheet. A leading apostrophe makes Sheets store it
    /// as plain text and is not displayed.
    static func text(_ value: String) -> String {
        guard let first = value.first, "=+-@".contains(first) else { return value }
        return "'" + value
    }

    /// A blank cell, not "0", when there is no data: a day without a Watch reading has no
    /// resting heart rate, and a 0 would drag every average an AI computes toward zero.
    static func number(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

// MARK: - First-connect sweep start

enum SweepStart {
    /// One type's answer to "what is your oldest sample": a date, nil for a type with no
    /// samples at all (legitimately empty), or an error.
    typealias TypeResult = Result<Date?, Error>

    /// The day a first connect sweeps from: the oldest sample across the types, floored. A
    /// failed query THROWS. Skipping it would quietly start the sweep at a later type's
    /// oldest day and leave the earlier history out of the sheet with no sign of why.
    static func resolve(_ results: [TypeResult], today: Date, floor: Date, calendar: Calendar) throws -> Date {
        var earliest = today
        for result in results {
            if let date = try result.get(), date < earliest { earliest = date }
        }
        return max(calendar.startOfDay(for: earliest), floor)
    }
}

// MARK: - Sheet grid

enum GridGrowth {
    /// The height of every tab in a sheet the app creates.
    static let defaultRows = 1000

    /// Rows to append to a tab so it holds `needed` rows, plus `headroom` spare so the next
    /// growth is far off. Nothing is added while the tab already holds `needed`. A new Google sheet is
    /// 1000 rows tall and `values:batchUpdate` refuses a range past the last row ("exceeds
    /// grid limits"), so a decade of days (about 3,650 rows) has to grow the tab first.
    static func rowsToAdd(currentRows: Int, needed: Int, headroom: Int = 0) -> Int {
        currentRows >= needed ? 0 : needed + headroom - currentRows
    }

    /// The `spreadsheets:batchUpdate` body that appends `count` rows to a tab.
    static func appendRowsBody(sheetId: Int, count: Int) -> [String: Any] {
        ["requests": [["appendDimension": ["sheetId": sheetId, "dimension": "ROWS", "length": count]]]]
    }
}

// MARK: - History version

enum HistoryVersion {
    /// Bumped when an already-connected sheet needs its full history rebuilt. 1: builds 54-55
    /// could start a first sync after the person's earliest data, and wrote raw HealthKit
    /// workout names. 2: build 58 records each type's oldest sample (HistoryFound) on the
    /// rebuild, for a sheet that still started on 2026-08-22 after build 57's rebuild.
    /// 3: build 59. Sheets built under iOS 27 limited ("Past 30 Days") access before the
    /// app recorded the cutoff (AccessLimit) rebuild once, in case access has since widened.
    /// 4: 1.0.3. The sweep start now considers every type the sheet reads, not only steps,
    /// heart rate, sleep and workouts, so a sheet whose oldest data is weight, HRV or resting
    /// HR starts earlier; rebuild once so existing sheets pick that history up.
    static let current = 4

    /// True for a sheet that already has rows but was last swept before `current`. A sheet
    /// that has never written (`lastWrittenDay == nil`) does a full sweep anyway.
    static func needsRebuild(lastWrittenDay: String?, historyVersion: Int?) -> Bool {
        lastWrittenDay != nil && (historyVersion ?? 0) < current
    }
}

// MARK: - Limited history access (iOS 27)

enum AccessLimit {
    /// True when iOS's limited-history cutoff was lifted or moved earlier since the last pass.
    /// The sheet was built under the old cutoff and a rebuild is the only way to fill in the
    /// older days. Unknown before (nil previous) is not a widening.
    static func widened(previous: String?, current: String?) -> Bool {
        guard let previous else { return false }
        guard let current else { return true }
        return current < previous
    }
}

// MARK: - Workout names

enum WorkoutName {
    /// "HKWorkoutActivityTypeUnderwaterDiving" -> "Underwater Diving". The raw identifier is
    /// what the database destination stores; a person reading a sheet should not see it.
    static func display(fromIdentifier id: String) -> String {
        let prefix = "HKWorkoutActivityType"
        let core = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        var out = ""
        let chars = Array(core)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, !chars[i - 1].isUppercase || (i + 1 < chars.count && chars[i + 1].isLowercase) {
                out.append(" ")
            }
            out.append(c)
        }
        return out.isEmpty ? id : out
    }
}

// MARK: - Date keys in the Daily tab's column A

enum DateKeys {
    /// "yyyy-MM-dd" exactly, as this app writes it. Anything else in column A (a person's
    /// note, "1/5/2020", a bare year, a number that Sheets turned into a 1900 date) is theirs.
    static func isKey(_ s: String) -> Bool {
        let c = Array(s.utf8)
        guard c.count == 10, c[4] == 45, c[7] == 45 else { return false }
        for (i, b) in c.enumerated() where i != 4 && i != 7 { if b < 48 || b > 57 { return false } }
        let month = Int(s.dropFirst(5).prefix(2))!, day = Int(s.suffix(2))!
        return (1...12).contains(month) && (1...31).contains(day)
    }

    /// The first day the sheet really holds. Keys before 2000 are ignored: HealthKit did not
    /// exist, so they are a misread number or typed text, and one would make a rebuild look
    /// safe when it is not (or, read the other way, refuse it forever).
    static func earliestHeld(_ column: [String], minYear: Int = 2000) -> String? {
        column.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isKey($0) && Int($0.prefix(4))! >= minYear }
            .min()
    }

    /// Sheet row runs (1-based, column A starts at row 2) below the `keptRows` rows a rebuild
    /// just wrote whose column A is a date key. Only those are ours to clear; a person's text
    /// below the table is left alone.
    static func staleRuns(_ column: [String], keptRows: Int) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for (i, raw) in column.enumerated() {
            let row = i + 2
            guard row > keptRows, isKey(raw.trimmingCharacters(in: .whitespaces)) else { continue }
            if let last = runs.last, last.upperBound == row - 1 { runs[runs.count - 1] = last.lowerBound...row }
            else { runs.append(row...row) }
        }
        return runs
    }
}

// MARK: - Rebuild backoff

enum RebuildBackoff {
    /// After a rebuild fails or is refused, foreground passes do incremental work only until
    /// this long has passed, so a failing rebuild does not repeat 20 chunks of queries on
    /// every app open.
    static let interval: TimeInterval = 6 * 3600
    static func isBlocked(notBefore: Date?, now: Date) -> Bool { (notBefore ?? .distantPast) > now }
}

#endif

// MARK: - Splitting a query around days HealthKit refuses

// Outside H4A_SHEETS: live sync and the history import split refused hourly totals with it too,
// passing hours where the Sheets path passes days (HealthKitManager.hourlyTotals, GitHub #28).
import Foundation

enum RangeSplit {
    struct Outcome<T> {
        /// Each piece that was read, with the days it covers (ascending, contiguous).
        var parts: [(days: [Date], value: T)] = []
        /// Single days that still failed with a splittable error.
        var failedDays: [Date] = []
    }

    /// Runs `query` over `days`. When it throws an error `splittable` accepts, each half is
    /// retried, down to single days. HealthKit can refuse a statistics collection over a range
    /// with "Unable to invalidate interval: no data source available" (com.apple.healthkit 3),
    /// a framework bug Apple has acknowledged without a fix (FB22221658), while a shorter range
    /// with the same anchor succeeds. Without this, one bad day failed the whole 180-day chunk
    /// on every pass and the Daily tab never got past it (support report, 2026-10-17).
    /// Any other error is rethrown, so a locked device or a cancelled task still fails the pass.
    /// A range refused on every day is NOT rethrown: a one-day retry of a day still refused is
    /// exactly that case, and throwing there failed every pass again (review, 2026-10-20). Every
    /// failed day is returned instead, and the caller reports and retries them.
    static func run<T>(_ days: [Date], splittable: (Error) -> Bool,
                       _ query: ([Date]) async throws -> T) async throws -> Outcome<T> {
        var out = Outcome<T>()
        try await split(days, splittable, query, &out)
        return out
    }

    private static func split<T>(_ days: [Date], _ splittable: (Error) -> Bool, _ query: ([Date]) async throws -> T,
                                 _ out: inout Outcome<T>) async throws {
        guard !days.isEmpty else { return }
        do {
            out.parts.append((days, try await query(days)))
        } catch let error where splittable(error) {
            guard days.count > 1 else { out.failedDays.append(days[0]); return }
            let mid = days.count / 2
            try await split(Array(days[..<mid]), splittable, query, &out)
            try await split(Array(days[mid...]), splittable, query, &out)
        }
    }
}

// MARK: - Hours HealthKit refused to total

/// Hourly totals HealthKit refused (RangeSplit), per type, waiting to be asked again. Persisted
/// by RefusedHours; pure here so the off-device harness tests it.
///
/// Stored as runs of consecutive hours, [first hour, count], hours counted from 1970 in UTC.
/// A refusal covers whole stretches, so a plain list would grow by 24 entries a day per type
/// for as long as a phone stays affected.
struct RefusedHourLedger: Codable, Equatable {
    private(set) var runs: [String: [[Int]]] = [:]
    /// Per type: no retry before this time (seconds since 1970), so an affected phone does not
    /// re-ask on every background wake. Set after every retry that leaves hours waiting.
    private(set) var retryAfter: [String: Double] = [:]
    /// Per type: the hour the next retry window starts from. The window moves past each one it
    /// asks, wrapping at the end, so hours HealthKit refuses for good cannot hold the same
    /// window forever while newer ones are never asked (review, 2026-10-26).
    private(set) var cursor: [String: Int] = [:]

    /// After a retry HealthKit refused entirely.
    static let backoff: TimeInterval = 6 * 3600
    /// After a retry that got some answers. A partial answer used to clear the wait, which let
    /// one answered hour buy a full re-split of the rest on every wake (review, 2026-10-26).
    static let minInterval: TimeInterval = 3600

    init() {}

    /// Every field optional on decode, so a ledger saved before a field existed still reads.
    /// A strict decode fails, and a failed decode is a ledger the app can no longer act on
    /// (Codex review, 2026-10-26).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent([String: [[Int]]].self, forKey: .runs) ?? [:]
        retryAfter = try c.decodeIfPresent([String: Double].self, forKey: .retryAfter) ?? [:]
        cursor = try c.decodeIfPresent([String: Int].self, forKey: .cursor) ?? [:]
    }

    /// After a retry that failed outright (not a refusal): wait the full backoff, so an error
    /// that repeats does not re-run the retry on every wake.
    mutating func backOff(_ type: String, now: Date) {
        guard runs[type] != nil else { return }
        retryAfter[type] = now.timeIntervalSince1970 + Self.backoff
    }

    static func hourIndex(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 3600).rounded(.down)) }
    static func date(_ hour: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(hour) * 3600) }

    var pendingTypes: [String] { runs.keys.sorted() }

    func hours(for type: String) -> Set<Int> {
        var out = Set<Int>()
        for run in runs[type] ?? [] where run.count == 2 && run[1] > 0 {
            out.formUnion(run[0]..<(run[0] + run[1]))
        }
        return out
    }

    private mutating func set(_ hours: Set<Int>, for type: String) {
        guard !hours.isEmpty else {
            runs[type] = nil
            retryAfter[type] = nil
            cursor[type] = nil
            return
        }
        var out: [[Int]] = []
        for h in hours.sorted() {
            if let last = out.last, last[0] + last[1] == h { out[out.count - 1][1] += 1 }
            else { out.append([h, 1]) }
        }
        runs[type] = out
    }

    mutating func add(_ dates: [Date], for type: String) {
        guard !dates.isEmpty else { return }
        set(hours(for: type).union(dates.map(Self.hourIndex)), for: type)
    }

    func hasPending(_ type: String) -> Bool { runs[type] != nil }

    /// Up to `limit` hours to ask again, oldest first from the cursor and wrapping, or none
    /// while waiting. Hours before `floor` are dropped for good: the import setting no longer
    /// covers them.
    mutating func due(for type: String, limit: Int, notBefore floor: Date?, now: Date) -> [Date] {
        var pending = hours(for: type)
        if let floor {
            let kept = pending.filter { $0 >= Self.hourIndex(floor) }
            if kept.count != pending.count { set(kept, for: type); pending = kept }
        }
        guard !pending.isEmpty, (retryAfter[type] ?? 0) <= now.timeIntervalSince1970 else { return [] }
        let sorted = pending.sorted()
        let from = cursor[type] ?? Int.min
        let window = sorted.filter { $0 >= from } + sorted.filter { $0 < from }
        return window.prefix(limit).map(Self.date)
    }

    /// After asking `asked` again: answered hours leave, `stillRefused` stay, and the next
    /// window starts after the last hour asked. Hours still waiting set the next wait.
    mutating func resolve(asked: [Date], stillRefused: [Date], for type: String, now: Date) {
        let refused = Set(stillRefused.map(Self.hourIndex))
        let askedHours = asked.map(Self.hourIndex)
        let answered = Set(askedHours).subtracting(refused)
        set(hours(for: type).subtracting(answered), for: type)
        guard runs[type] != nil else { return }
        if let last = askedHours.max() { cursor[type] = last + 1 }
        retryAfter[type] = now.timeIntervalSince1970 + (answered.isEmpty ? Self.backoff : Self.minInterval)
    }
}
