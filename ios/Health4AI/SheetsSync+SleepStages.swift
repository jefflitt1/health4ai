#if H4A_SHEETS
// Compiled only with H4A_SHEETS (on in Debug and Release since 1.0.1; see docs/sheets-build-gate.md).
import Foundation

// The Sleep stages tab's part of a Sheets pass, kept apart from SheetsSync.swift's Daily and
// Workouts sequencing. Tested the same way, through SheetsSyncCore.run with fakes.

extension SheetsSyncCore {
    /// Nights re-read on every pass. Wider than Daily's `overlapDays`: a ring or a Watch left
    /// off the charger can hand Health a night's sleep days later, and a re-read costs only a
    /// week of HealthKit records, each skipped by its ID when the tab already has it.
    static let sleepOverlapDays = 7
    /// Rows per append to the Sleep stages and Workouts tabs. Ten years of nights is ~100k
    /// rows; one request that size is slow and fragile on a phone connection.
    static let appendChunkRows = 2000

    /// Appends sleep records the tab does not hold yet, from the night after the last one
    /// written (less the overlap) through last night, saving progress per chunk. Never clears
    /// or overwrites a row, like Workouts.
    func syncSleepStages(id: String, progress: inout SheetsProgress, today: Date,
                         persist: (SheetsProgress) -> Void) async throws -> Int {
        let tab = SheetTabs.sleepStages
        // New tab, or a person deleted it: start it from the beginning.
        if try await api.ensureTab(spreadsheetId: id, title: tab) { progress.sleepStagesThrough = nil }
        if progress.sleepStagesThrough == nil {
            // Written on every sweep from the beginning, not only when the tab is added: a pass
            // cut off between adding the tab and this write would otherwise leave no header,
            // and every row would then sit one row above where the ID check reads.
            var header = [(range: SheetTabs.range(tab, "A1:G1"), rows: [SleepStageLayout.header])]
            header += rebuildExtras   // the About text that describes the new tab
            try await api.writeRanges(spreadsheetId: id, header)
        }
        let start: Date
        if let through = progress.sleepStagesThrough.flatMap({ Self.date(fromKey: $0, calendar: calendar) }) {
            start = min(calendar.date(byAdding: .day, value: -Self.sleepOverlapDays, to: through)!, today)
        } else {
            // No sleep recorded at all: nothing to save, and nothing marked done, so history
            // that arrives later (a new Watch, an import) is still picked up.
            guard let oldest = try await source.oldestSleepRecord() else { return 0 }
            let night = Self.date(fromKey: SleepMath.night(for: oldest, calendar: calendar), calendar: calendar)!
            start = min(max(night, Self.historyFloor(today, calendar: calendar)), today)
        }

        // Record IDs already in the tab from a day before `start` down (a day early, because a
        // time-zone change can move a record's night by one).
        let fromKey = DayKey.string(for: calendar.date(byAdding: .day, value: -1, to: start)!, calendar: calendar)
        let nights = try await api.readDateColumn(spreadsheetId: id, range: SheetTabs.range(tab, "A2:A"))
        var known = Set<String>()
        if let row = SleepStageLayout.firstRow(nights: nights, onOrAfter: fromKey) {
            let col = SleepStageLayout.idColumn
            known = Set(try await api.readColumn(spreadsheetId: id, range: SheetTabs.range(tab, "\(col)\(row):\(col)")))
        }

        var added = 0
        var chunkStart = start
        while chunkStart <= today {
            try Task.checkCancellation()
            let chunkEnd = min(calendar.date(byAdding: .day, value: Self.chunkDays - 1, to: chunkStart)!, today)
            let fresh = try await source.sleepStageRows(nights: chunkStart, through: chunkEnd)
                .filter { !known.contains($0[SleepStageLayout.idIndex]) }
            try await appendInPieces(id: id, range: SheetTabs.range(tab, "A:G"), rows: fresh)
            known.formUnion(fresh.map { $0[SleepStageLayout.idIndex] })
            added += fresh.count
            progress.sleepStagesThrough = DayKey.string(for: chunkEnd, calendar: calendar)
            persist(progress)
            chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
        }
        return added
    }

    /// One append per `appendChunkRows` rows. A failure part-way leaves the earlier pieces in
    /// the sheet; both callers skip rows by ID, so the next pass adds only the rest.
    func appendInPieces(id: String, range: String, rows: [[String]]) async throws {
        var i = 0
        while i < rows.count {
            let slice = Array(rows[i..<min(i + Self.appendChunkRows, rows.count)])
            try await api.append(spreadsheetId: id, range: range, rows: slice)
            i += slice.count
        }
    }
}
#endif
