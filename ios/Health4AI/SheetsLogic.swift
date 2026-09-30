#if H4A_SHEETS
// Compiled only with H4A_SHEETS (off in Release by default; see docs/sheets-build-gate.md).
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
    /// workout names.
    static let current = 1

    /// True for a sheet that already has rows but was last swept before `current`. A sheet
    /// that has never written (`lastWrittenDay == nil`) does a full sweep anyway.
    static func needsRebuild(lastWrittenDay: String?, historyVersion: Int?) -> Bool {
        lastWrittenDay != nil && (historyVersion ?? 0) < current
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
#endif
