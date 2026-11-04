#if H4A_SHEETS
// Compiled only with H4A_SHEETS (on in Debug and Release since 1.0.1; see docs/sheets-build-gate.md).
import Foundation
import os

// Minimal Google Sheets API v4 client: the few calls the Sheets destination needs, over
// URLSession with the token from GoogleTokenStore. No SDK, same as GoogleAuth.

struct CreatedSpreadsheet: Decodable {
    let spreadsheetId: String
    let spreadsheetUrl: String
}

final class SheetsClient: SheetsAPI, @unchecked Sendable {
    static let shared = SheetsClient()
    private static let base = URL(string: "https://sheets.googleapis.com/v4/spreadsheets")!
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "SheetsClient")

    private let tokens: GoogleTokenStore
    init(tokens: GoogleTokenStore = .shared) { self.tokens = tokens }

    /// Creates the spreadsheet with its tabs and a frozen header row on each.
    func createSpreadsheet(title: String, tabs: [String]) async throws -> CreatedSpreadsheet {
        let body: [String: Any] = [
            "properties": ["title": title],
            "sheets": tabs.map { ["properties": ["title": $0, "gridProperties": ["frozenRowCount": 1]]] },
        ]
        // Not resent on a 5xx: a create Google applied before failing would leave a second file.
        let data = try await send(method: "POST", url: Self.base, json: body, replay: .unsafe)
        guard let created = try? JSONDecoder().decode(CreatedSpreadsheet.self, from: data) else {
            throw SheetsError.badResponse
        }
        return created
    }

    /// One column as strings, e.g. `Daily!A2:A`. Empty cells inside the range come back as "".
    func readColumn(spreadsheetId: String, range: String) async throws -> [String] {
        var comps = URLComponents(url: valuesURL(spreadsheetId, range), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "majorDimension", value: "COLUMNS")]
        let data = try await send(method: "GET", url: comps.url!, json: nil)
        struct ValueRange: Decodable { let values: [[String]]? }
        let decoded = try JSONDecoder().decode(ValueRange.self, from: data)
        return decoded.values?.first ?? []
    }

    /// One column as stored (UNFORMATTED_VALUE): numbers come back as JSON numbers and are
    /// written as en_US_POSIX digits (SheetCell.stored), so a German sheet's "7,5" reads as "7.5".
    func readValueColumn(spreadsheetId: String, range: String) async throws -> [String] {
        var comps = URLComponents(url: valuesURL(spreadsheetId, range), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "majorDimension", value: "COLUMNS"),
            URLQueryItem(name: "valueRenderOption", value: "UNFORMATTED_VALUE"),
        ]
        let data = try await send(method: "GET", url: comps.url!, json: nil)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SheetsError.badResponse
        }
        return try ((object["values"] as? [[Any]])?.first ?? []).map { cell in
            guard let text = SheetCell.stored(cell) else { throw SheetsError.badResponse }
            return text
        }
    }

    /// The Daily tab's date column as day keys. Read UNFORMATTED: a USER_ENTERED date is
    /// displayed in the sheet's locale ("9/28/2026"), so the formatted text never matches our
    /// "2026-09-28" keys and every sync would append duplicate days (Reviewboard A, 2026-09-28).
    /// Text a person typed into the column comes back as text and is kept as-is.
    func readDateColumn(spreadsheetId: String, range: String) async throws -> [String] {
        var comps = URLComponents(url: valuesURL(spreadsheetId, range), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "majorDimension", value: "COLUMNS"),
            URLQueryItem(name: "valueRenderOption", value: "UNFORMATTED_VALUE"),
            URLQueryItem(name: "dateTimeRenderOption", value: "SERIAL_NUMBER"),
        ]
        let data = try await send(method: "GET", url: comps.url!, json: nil)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SheetsError.badResponse
        }
        let column = (object["values"] as? [[Any]])?.first ?? []
        return column.map { cell in
            if let number = cell as? NSNumber { return DayKey.string(fromSheetsSerial: number.doubleValue) ?? "" }
            return (cell as? String) ?? ""
        }
    }

    /// Writes several ranges in ONE request. The Sheets quota is about 60 writes per minute
    /// per user, so a sync pass must never write row by row.
    func writeRanges(spreadsheetId: String, _ ranges: [(range: String, rows: [[String]])]) async throws {
        guard !ranges.isEmpty else { return }
        let url = Self.base.appendingPathComponent(spreadsheetId).appendingPathComponent("values:batchUpdate")
        let body: [String: Any] = [
            // USER_ENTERED so "2026-09-28" becomes a real date. Numeric cells go as JSON numbers
            // (SheetPayload), so the sheet's locale cannot turn "7.50" into text or a date.
            "valueInputOption": "USER_ENTERED",
            "data": ranges.map { ["range": $0.range, "values": SheetPayload.values(range: $0.range, rows: $0.rows)] },
        ]
        _ = try await send(method: "POST", url: url, json: body)
    }

    /// Makes sure `tab` has at least `needed` rows (growing by `headroom` extra when it must) and returns its row count. A new sheet is
    /// 1000 rows tall and a range write past the last row fails ("exceeds grid limits").
    func ensureRows(spreadsheetId: String, tab: String, needed: Int, headroom: Int) async throws -> Int {
        var comps = URLComponents(url: Self.base.appendingPathComponent(spreadsheetId), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "fields", value: "sheets.properties(sheetId,title,gridProperties.rowCount)")]
        let data = try await send(method: "GET", url: comps.url!, json: nil)
        struct Meta: Decodable {
            struct Sheet: Decodable {
                struct Props: Decodable {
                    struct Grid: Decodable { let rowCount: Int }
                    let sheetId: Int; let title: String; let gridProperties: Grid
                }
                let properties: Props
            }
            let sheets: [Sheet]
        }
        guard let props = try JSONDecoder().decode(Meta.self, from: data).sheets.map(\.properties)
            .first(where: { $0.title == tab }) else { throw SheetsError.badResponse }
        let add = GridGrowth.rowsToAdd(currentRows: props.gridProperties.rowCount, needed: needed, headroom: headroom)
        if add > 0 {
            let url = Self.base.appendingPathComponent("\(spreadsheetId):batchUpdate")
            // .unsafe: a resent appendDimension adds the rows twice. The next pass re-reads the height.
            _ = try await send(method: "POST", url: url, json: GridGrowth.appendRowsBody(sheetId: props.sheetId, count: add),
                               replay: .unsafe)
        }
        return props.gridProperties.rowCount + add
    }

    /// Adds `title` as a new tab with a frozen header row, unless the sheet already has it.
    /// Checked on every pass that writes the tab, so a tab the person deleted comes back
    /// instead of every append failing on a range that no longer exists.
    func ensureTab(spreadsheetId: String, title: String) async throws -> Bool {
        var comps = URLComponents(url: Self.base.appendingPathComponent(spreadsheetId), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "fields", value: "sheets.properties.title")]
        let data = try await send(method: "GET", url: comps.url!, json: nil)
        struct Meta: Decodable {
            struct Sheet: Decodable { struct Props: Decodable { let title: String }; let properties: Props }
            let sheets: [Sheet]
        }
        if try JSONDecoder().decode(Meta.self, from: data).sheets.contains(where: { $0.properties.title.caseInsensitiveCompare(title) == .orderedSame }) {
            return false
        }
        let url = Self.base.appendingPathComponent("\(spreadsheetId):batchUpdate")
        let body: [String: Any] = ["requests": [["addSheet": ["properties": [
            "title": title, "gridProperties": ["frozenRowCount": 1]]]]]]
        // .unsafe: a resent addSheet that Google already applied fails as a duplicate tab name.
        _ = try await send(method: "POST", url: url, json: body, replay: .unsafe)
        Self.logger.info("Added tab \(title, privacy: .public)")
        return true
    }

    /// Clears values (not formatting or the header) from the given A1 ranges.
    func clear(spreadsheetId: String, ranges: [String]) async throws {
        let url = Self.base.appendingPathComponent(spreadsheetId).appendingPathComponent("values:batchClear")
        _ = try await send(method: "POST", url: url, json: ["ranges": ranges])
    }

    /// Appends rows after the last row of the table in `range` (e.g. `Workouts!A:H`). Never
    /// resent on a 5xx (Google may have applied it): SheetsSyncCore.appendInPieces retries it
    /// after re-reading the tab's IDs, so a retry cannot write a row twice.
    func append(spreadsheetId: String, range: String, rows: [[String]]) async throws {
        guard !rows.isEmpty else { return }
        var comps = URLComponents(url: valuesURL(spreadsheetId, range, suffix: ":append"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "valueInputOption", value: "USER_ENTERED"),
            URLQueryItem(name: "insertDataOption", value: "INSERT_ROWS"),
        ]
        _ = try await send(method: "POST", url: comps.url!, json: ["values": SheetPayload.values(range: range, rows: rows)],
                           replay: .unsafe)
    }

    // MARK: Transport

    private func valuesURL(_ id: String, _ range: String, suffix: String = "") -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encoded = range.addingPercentEncoding(withAllowedCharacters: allowed) ?? range
        return URL(string: "\(Self.base.absoluteString)/\(id)/values/\(encoded)\(suffix)")!
    }

    /// One retry after a 401 with a forced token refresh; up to three backoff retries on 429,
    /// and on 5xx only for a `.safe` request; everything else is thrown to the caller, which
    /// logs it to Sync History. A 403 forgets the sheet only for Google's plain "caller does not
    /// have permission" (SheetsForbidden); any other 403 keeps it and is thrown as HTTP 403.
    /// The decision for each answer is SheetsResponse.step (pure, tested off device).
    private func send(method: String, url: URL, json: Any?, replay: SheetsReplay = .safe) async throws -> Data {
        var forcedRefresh = false
        var attempt = 0
        while true {
            let token = try await tokens.validAccessToken(forceRefresh: forcedRefresh)
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let json {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: json)
            }
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch SheetsResponse.step(status: status, body: data, attempt: attempt,
                                       forcedRefresh: forcedRefresh, replay: replay) {
            case .done:
                return data
            case .refreshTokenAndRetry:
                forcedRefresh = true
            case .retry(let seconds):
                attempt += 1
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            case .accessRevoked:
                throw GoogleAuthError.accessRevoked
            case .spreadsheetMissing:
                throw SheetsError.spreadsheetMissing
            case .fail(let status):
                let detail = String(data: data, encoding: .utf8) ?? ""
                Self.logger.error("Sheets \(method, privacy: .public) \(status): \(detail, privacy: .private)")
                throw SheetsError.http(status: status, detail: detail)
            }
        }
    }
}
#endif
