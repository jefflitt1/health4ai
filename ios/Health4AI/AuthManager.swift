import Foundation
import Security

// MARK: - AuthManager

/// Handles Supabase email/password authentication via raw REST calls.
/// JWT is stored in and retrieved from the iOS Keychain.
///
/// On the Netlify destination there is no sign-in: the site issues a Device key, which is the
/// bearer token itself. `isSignedIn` and `validToken` answer for whichever destination is
/// chosen, so SyncEngine, BulkExportManager and AppDelegate need no Netlify-specific code.
@MainActor
final class AuthManager: ObservableObject {

    // MARK: - Types

    struct AuthResponse: Decodable {
        let accessToken: String
        let tokenType: String
        let expiresIn: Int
        let refreshToken: String
        let user: UserInfo

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case tokenType    = "token_type"
            case expiresIn    = "expires_in"
            case refreshToken = "refresh_token"
            case user
        }
    }

    struct UserInfo: Decodable {
        let id: String
        let email: String?
    }

    struct AuthError: Decodable {
        let error: String?
        let errorDescription: String?
        let message: String?
        let msg: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
            case message
            case msg
        }

        var localizedMessage: String {
            errorDescription ?? message ?? msg ?? error ?? "Unknown authentication error"
        }
    }

    enum AuthManagerError: LocalizedError {
        case invalidURL
        case encodingFailed
        case serverError(String)
        case tokenMissing
        case missingAnonKey
        case keychainError(OSStatus)
        case deviceKeyRejected
        case siteAnswered(Int)
        case notAnIngest

        var errorDescription: String? {
            switch self {
            case .invalidURL:        return "Invalid server URL"
            case .encodingFailed:    return "Failed to encode request"
            case .serverError(let m): return m
            case .tokenMissing:      return "No auth token found, please sign in again"
            case .missingAnonKey:    return "Supabase anon key not configured"
            case .keychainError(let s): return "Keychain error: \(s)"
            case .deviceKeyRejected: return "Your site rejected this Device key. Issue a new one on your site's setup page."
            case .siteAnswered(let code): return "Your site answered with HTTP \(code). Check the Site URL."
            case .notAnIngest:       return "That address answered, but not as a health4ai site. Check the Site URL."
            }
        }
    }

    // MARK: - Keychain constants

    private static let keychainService = "com.healthkitbridge.auth"
    private static let accessTokenKey  = "access_token"
    private static let refreshTokenKey = "refresh_token"
    private static let userEmailKey    = "user_email"
    private static let expiryKey       = "token_expiry"
    // MARK: - Supabase anon key

    /// Returns the configured Supabase anon key from Keychain, or throws `.missingAnonKey` if absent.
    private func requireAnonKey() throws -> String {
        guard let anonKey = CredentialKeychain.load(forKey: "hkb.supabaseAnonKey"),
              !anonKey.isEmpty else {
            throw AuthManagerError.missingAnonKey
        }
        return anonKey
    }

    // MARK: - JWT expiry

    /// Decodes the `exp` (Unix timestamp) claim from a JWT's payload segment.
    /// Returns nil for malformed tokens so callers can treat them as expired.
    private func jwtExpiry(from token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }

        // Base64url-decode the payload (middle) segment.
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Supabase base URL (extracted from endpoint)

    /// The Supabase project URL is derived from the ingest endpoint by stripping the path.
    private func supabaseBaseURL(from serverURL: String) -> String {
        guard let url = URL(string: serverURL),
              let scheme = url.scheme,
              let host = url.host else {
            return serverURL
        }
        return "\(scheme)://\(host)"
    }

    // MARK: - Netlify Device key

    /// CredentialKeychain account holding the Device key (listed in `sensitiveKeys`).
    nonisolated static let netlifyDeviceKey = "hkb.netlifyDeviceKey"
    /// Set once the site has accepted the key, so a half-typed key never starts a sync.
    private static let netlifyConnectedKey = "hkb.netlifyConnected"

    /// Whether the chosen destination is a Netlify site. Read from UserDefaults rather than
    /// SyncState so this stays usable from every caller that already holds an AuthManager.
    private var usesDeviceKey: Bool {
        UserDefaults.standard.string(forKey: "hkb.connectionType") == ConnectionType.netlify.rawValue
    }

    var deviceKey: String? {
        // Trimmed: a key copied from a web page often carries a trailing space or newline, which
        // would make a valid key fail the site's hash lookup.
        guard let key = CredentialKeychain.load(forKey: Self.netlifyDeviceKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// The credential Test Connection should send for the chosen destination, if any.
    var bearerForTest: String? { usesDeviceKey ? deviceKey : currentToken }

    /// Checks the stored Device key against the site with the empty batch every ingest answers.
    /// Nothing is written to the site. Succeeds only on a 2xx that reads like a health4ai ingest
    /// (`{"inserted": 0, ...}`), so another site that answers any POST is not taken for one.
    /// The caller records the connection with `markDeviceKeyConnected` once it still wants it.
    func connectDeviceKey(endpoint: String) async throws {
        guard let url = URL(string: endpoint), url.scheme == "https" else { throw AuthManagerError.invalidURL }
        guard let key = deviceKey else { throw AuthManagerError.tokenMissing }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"samples":[]}"#.utf8)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200...299:
            guard SyncEngine.parseInsertedCount(data) != nil else { throw AuthManagerError.notAnIngest }
        case 401, 403:  throw AuthManagerError.deviceKeyRejected
        default:        throw AuthManagerError.siteAnswered(code)
        }
    }

    /// Records that the site accepted the stored Device key, so syncing may start.
    func markDeviceKeyConnected() {
        UserDefaults.standard.set(true, forKey: Self.netlifyConnectedKey)
    }

    // MARK: - Public interface

    /// Returns the current access token if one is stored and not expired.
    var currentToken: String? {
        get { loadFromKeychain(key: Self.accessTokenKey) }
    }

    var isSignedIn: Bool {
        if usesDeviceKey {
            return deviceKey != nil && UserDefaults.standard.bool(forKey: Self.netlifyConnectedKey)
        }
        return currentToken != nil
    }

    var storedEmail: String? {
        loadFromKeychain(key: Self.userEmailKey)
    }

    // MARK: - Sign in

    func signIn(email: String, password: String, serverURL: String) async throws -> AuthResponse {
        let baseURL = supabaseBaseURL(from: serverURL)
        guard let url = URL(string: "\(baseURL)/auth/v1/token?grant_type=password") else {
            throw AuthManagerError.invalidURL
        }

        let body: [String: String] = ["email": email, "password": password]
        guard let bodyData = try? JSONEncoder().encode(body) else {
            throw AuthManagerError.encodingFailed
        }

        // Supabase requires the anon key for auth endpoints. Guard before the network call
        // so a missing key surfaces a clear error rather than a generic server 401.
        let anonKey = try requireAnonKey()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = bodyData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthManagerError.serverError("No HTTP response")
        }

        if httpResponse.statusCode == 200 {
            let decoder = JSONDecoder()
            let authResponse = try decoder.decode(AuthResponse.self, from: data)
            // Persist tokens to Keychain
            try saveToKeychain(key: Self.accessTokenKey, value: authResponse.accessToken)
            try saveToKeychain(key: Self.refreshTokenKey, value: authResponse.refreshToken)
            if let email = authResponse.user.email {
                try saveToKeychain(key: Self.userEmailKey, value: email)
            }
            let expiry = Date().addingTimeInterval(TimeInterval(authResponse.expiresIn))
            UserDefaults.standard.set(expiry, forKey: Self.expiryKey)
            return authResponse
        } else {
            let decoder = JSONDecoder()
            let errorBody = (try? decoder.decode(AuthError.self, from: data))
            throw AuthManagerError.serverError(errorBody?.localizedMessage ?? "HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Refresh token

    func refreshAccessToken(serverURL: String) async throws {
        let baseURL = supabaseBaseURL(from: serverURL)
        guard let refreshToken = loadFromKeychain(key: Self.refreshTokenKey) else {
            throw AuthManagerError.tokenMissing
        }
        guard let url = URL(string: "\(baseURL)/auth/v1/token?grant_type=refresh_token") else {
            throw AuthManagerError.invalidURL
        }

        let body: [String: String] = ["refresh_token": refreshToken]
        guard let bodyData = try? JSONEncoder().encode(body) else {
            throw AuthManagerError.encodingFailed
        }

        let anonKey = try requireAnonKey()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = bodyData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AuthManagerError.serverError("Token refresh failed")
        }

        let decoder = JSONDecoder()
        let authResponse = try decoder.decode(AuthResponse.self, from: data)
        try saveToKeychain(key: Self.accessTokenKey, value: authResponse.accessToken)
        try saveToKeychain(key: Self.refreshTokenKey, value: authResponse.refreshToken)
        let expiry = Date().addingTimeInterval(TimeInterval(authResponse.expiresIn))
        UserDefaults.standard.set(expiry, forKey: Self.expiryKey)
    }

    // MARK: - Sign out

    func signOut() {
        // One destination at a time, so signing out of either forgets the Device key too.
        CredentialKeychain.save("", forKey: Self.netlifyDeviceKey)
        UserDefaults.standard.removeObject(forKey: Self.netlifyConnectedKey)
        deleteFromKeychain(key: Self.accessTokenKey)
        deleteFromKeychain(key: Self.refreshTokenKey)
        deleteFromKeychain(key: Self.userEmailKey)
        deleteFromKeychain(key: "h4_sync_token") // remove legacy keychain entry if present
        UserDefaults.standard.removeObject(forKey: Self.expiryKey)
    }

    // MARK: - Token validity

    var isTokenExpired: Bool {
        // Source of truth is the JWT `exp` claim, not the mutable UserDefaults cache.
        // A malformed/missing token decodes to nil and is treated as expired.
        guard let token = currentToken,
              let expiry = jwtExpiry(from: token) else {
            return true
        }
        // Treat token as expired 60 seconds before actual expiry to allow refresh time
        return Date() >= expiry.addingTimeInterval(-60)
    }

    /// Returns a valid access token, refreshing it if necessary.
    func validToken(serverURL: String) async throws -> String {
        if usesDeviceKey {
            // A Device key does not expire; the site revokes it instead, which the ingest
            // reports as a 401 like any rejected token.
            guard let key = deviceKey else { throw AuthManagerError.tokenMissing }
            return key
        }
        if isTokenExpired {
            try await refreshAccessToken(serverURL: serverURL)
        }
        guard let token = currentToken else {
            throw AuthManagerError.tokenMissing
        }
        return token
    }

    // MARK: - Keychain helpers

    private func saveToKeychain(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw AuthManagerError.encodingFailed
        }

        // Delete existing item first
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService as CFString,
            kSecAttrAccount: key as CFString
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [CFString: Any] = [
            kSecClass:                kSecClassGenericPassword,
            kSecAttrService:          Self.keychainService as CFString,
            kSecAttrAccount:          key as CFString,
            kSecValueData:            data as CFData,
            kSecAttrAccessible:       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthManagerError.keychainError(status)
        }
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService as CFString,
            kSecAttrAccount: key as CFString,
            kSecReturnData:  kCFBooleanTrue!,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private func deleteFromKeychain(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService as CFString,
            kSecAttrAccount: key as CFString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
