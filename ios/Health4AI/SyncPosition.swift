import Foundation

/// Which database the HealthKit anchors and import progress were built against.
///
/// The anchors record what one database has received. Kept as they are after connecting to a
/// different database, they would send it only samples newer than the last sync to the old one,
/// and none of the history. Google Sheets never reads or moves them, so only connecting to a
/// database (Supabase or a Netlify site) is checked, and only once that connection succeeds:
/// choosing a destination in the picker changes nothing by itself.
///
/// Foundation only, so `ios/scripts/test_sync_position.sh` compiles it without the app.
enum SyncPosition {
    /// UserDefaults key holding the ingest endpoint the sync position belongs to.
    static let endpointKey = "hkb.syncPositionEndpoint"

    /// Whether connecting to `endpoint` must restart the sync position.
    ///
    /// `recorded` is nil on an install from before this record existed. Supabase was the only
    /// database then, so a nil record belongs to Supabase: signing in to Supabase keeps the
    /// position, connecting to a Netlify site restarts it.
    static func needsReset(recorded: String?, connecting endpoint: String, connectingIsSupabase: Bool) -> Bool {
        guard let recorded else { return !connectingIsSupabase }
        return normalized(recorded) != normalized(endpoint)
    }

    /// Surrounding whitespace, a trailing slash, and letter case in the scheme and host do not
    /// make a different database. The path keeps its case. Two hostnames for one site (a custom
    /// domain and its netlify.app address) still count as two.
    static func normalized(_ endpoint: String) -> String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard var parts = URLComponents(string: value) else { return value }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        return parts.string ?? value
    }
}
