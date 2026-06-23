import Foundation
import Security

// MARK: - AuthManager

/// Handles Supabase email/password authentication via raw REST calls.
/// JWT is stored in and retrieved from the iOS Keychain.
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

        var errorDescription: String? {
            switch self {
            case .invalidURL:        return "Invalid server URL"
            case .encodingFailed:    return "Failed to encode request"
            case .serverError(let m): return m
            case .tokenMissing:      return "No auth token found — please sign in again"
            case .missingAnonKey:    return "Supabase anon key not configured"
            case .keychainError(let s): return "Keychain error: \(s)"
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

    // MARK: - Public interface

    /// Returns the current access token if one is stored and not expired.
    var currentToken: String? {
        get { loadFromKeychain(key: Self.accessTokenKey) }
    }

    var isSignedIn: Bool {
        currentToken != nil
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
