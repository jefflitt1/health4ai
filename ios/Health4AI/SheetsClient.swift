import Foundation
import os

// Minimal Google Sheets API v4 client: the four calls the Sheets destination needs, over
// URLSession with the token from GoogleTokenStore. No SDK, same as GoogleAuth.

enum SheetsError: LocalizedError {
    /// The spreadsheet is gone: deleted, trashed, or (drive.file) no longer visible to the app.
    case spreadsheetMissing
    /// A first sync found no health data at all. HealthKit reports a DENIED read as an empty
    /// result, so this is usually missing Health access, not an empty history; treating it as
    /// success is how this app once showed a green "Complete" for three months with no data.
    case noHealthData
    /// iOS has never been asked for some type the daily summary reads. Unlike a denial this
    /// makes HealthKit throw, so it gets its own fix: ask, then sync.
    case healthNotAsked
    case http(status: Int, detail: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .spreadsheetMissing: return "Your health4ai sheet was deleted or moved out of reach."
        case .noHealthData: return "No health data found to add to your sheet."
        case .healthNotAsked: return "health4ai has not yet asked for all the Health data your sheet uses."
        case .http(let status, _): return "Google Sheets returned an error (HTTP \(status))."
        case .badResponse: return "Google Sheets returned an unexpected response."
        }
    }
}

struct CreatedSpreadsheet: Decodable {
    let spreadsheetId: String
    let spreadsheetUrl: String
}

final class SheetsClient: @unchecked Sendable {
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
        let data = try await send(method: "POST", url: Self.base, json: body)
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
            // USER_ENTERED so "2026-09-28" becomes a real date and "7.5" a number, which is
            // what makes the sheet chartable and lets an AI connector do arithmetic on it.
            "valueInputOption": "USER_ENTERED",
            "data": ranges.map { ["range": $0.range, "values": $0.rows] },
        ]
        _ = try await send(method: "POST", url: url, json: body)
    }

    /// Appends rows after the last row of the table in `range` (e.g. `Workouts!A:H`).
    func append(spreadsheetId: String, range: String, rows: [[String]]) async throws {
        guard !rows.isEmpty else { return }
        var comps = URLComponents(url: valuesURL(spreadsheetId, range, suffix: ":append"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "valueInputOption", value: "USER_ENTERED"),
            URLQueryItem(name: "insertDataOption", value: "INSERT_ROWS"),
        ]
        _ = try await send(method: "POST", url: comps.url!, json: ["values": rows])
    }

    // MARK: Transport

    private func valuesURL(_ id: String, _ range: String, suffix: String = "") -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encoded = range.addingPercentEncoding(withAllowedCharacters: allowed) ?? range
        return URL(string: "\(Self.base.absoluteString)/\(id)/values/\(encoded)\(suffix)")!
    }

    /// One retry after a 401 with a forced token refresh; up to three backoff retries on
    /// 429/5xx; everything else is thrown to the caller, which logs it to Sync History.
    private func send(method: String, url: URL, json: Any?) async throws -> Data {
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
            switch status {
            case 200...299:
                return data
            case 401 where !forcedRefresh:
                forcedRefresh = true
                continue
            case 404:
                throw SheetsError.spreadsheetMissing
            case 403 where String(data: data, encoding: .utf8)?.contains("PERMISSION_DENIED") == true:
                // With drive.file, a sheet the app can no longer see (ownership moved, access
                // removed) answers 403, not 404. Treated the same: offer a new sheet.
                throw SheetsError.spreadsheetMissing
            // `where` binds per pattern, so each carries its own limit: a bare `429` here
            // would retry a rate limit forever.
            case 429 where attempt < 3, 500...599 where attempt < 3:
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
                continue
            default:
                let detail = String(data: data, encoding: .utf8) ?? ""
                Self.logger.error("Sheets \(method, privacy: .public) \(status): \(detail, privacy: .private)")
                throw SheetsError.http(status: status, detail: detail)
            }
        }
    }
}
