import AuthenticationServices
import Foundation
import os
import UIKit

// Google sign-in for the "Save to Google Sheets" destination.
//
// No Google SDK: ASWebAuthenticationSession + OAuth PKCE against an iOS OAuth client, which
// has no client secret. The only scope is drive.file, so the app can see nothing in the
// person's Drive except the one spreadsheet it creates. Data goes phone -> Google directly;
// health4ai runs no server in this path (the conduit rule, same as the Supabase path).

enum GoogleOAuthConfig {
    // Public identifiers of the "health4ai iOS" client in Cloud project `health4ai`
    // (created 2026-09-28). Not secrets: an iOS client has none, PKCE stands in for one.
    static let clientID = "546712901991-u42nvqn1ksi7lnpji0rgdcuc4j8hbgtv.apps.googleusercontent.com"
    static let callbackScheme = "com.googleusercontent.apps.546712901991-u42nvqn1ksi7lnpji0rgdcuc4j8hbgtv"
    static var redirectURI: String { "\(callbackScheme):/oauth2redirect" }
    static let scope = "https://www.googleapis.com/auth/drive.file"

    static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
}

enum GoogleAuthError: LocalizedError {
    case cancelled
    case couldNotStart
    case badCallback
    case stateMismatch
    case scopeNotGranted
    case tokenRequestFailed(status: Int, detail: String)
    case notSignedIn
    /// Google refused the stored refresh token: the person removed health4ai's access in
    /// their Google Account, changed their password, or the token aged out. Only a fresh
    /// sign-in fixes it, so this is surfaced as "Reconnect Google", never retried.
    case accessRevoked

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Google sign-in was cancelled."
        case .couldNotStart: return "Couldn't open Google sign-in."
        case .badCallback: return "Google sign-in returned an unexpected response."
        case .stateMismatch: return "Google sign-in response didn't match this request. Please try again."
        case .scopeNotGranted:
            return "health4ai needs permission to create and update its own spreadsheet. Please sign in again and allow it."
        case .tokenRequestFailed(let status, _): return "Google sign-in failed (HTTP \(status))."
        case .notSignedIn: return "Not connected to Google."
        case .accessRevoked: return "Google access was removed or expired. Reconnect Google to keep your sheet updated."
        }
    }
}

// MARK: - Token store

/// Refresh token in the Keychain, access token in memory. Lock-guarded rather than an actor
/// for the same reason as SyncHistoryStore: callers include HKObserverQuery callbacks and
/// BGTask handlers that should not need a cross-actor hop just to get a header value.
final class GoogleTokenStore: @unchecked Sendable {
    static let shared = GoogleTokenStore()
    static let refreshTokenKey = "hkb.googleRefreshToken"

    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "GoogleAuth")
    private let lock = NSLock()
    private var accessToken: String?
    private var accessTokenExpiry: Date?

    var isSignedIn: Bool { CredentialKeychain.load(forKey: Self.refreshTokenKey) != nil }

    /// A bearer token good for at least another minute, refreshing if needed.
    /// `forceRefresh` is for the one retry after a 401 on a token we believed was valid.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh {
            lock.lock()
            let cached = accessToken, expiry = accessTokenExpiry
            lock.unlock()
            if let cached, let expiry, expiry.timeIntervalSinceNow > 60 { return cached }
        }
        guard let refresh = CredentialKeychain.load(forKey: Self.refreshTokenKey) else {
            throw GoogleAuthError.notSignedIn
        }
        let response = try await postToken([
            "client_id": GoogleOAuthConfig.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        remember(response)
        return response.accessToken
    }

    /// Exchanges the authorization code from the sign-in callback. Requires a refresh token
    /// in the answer: without one the sheet would stop updating an hour after sign-in, in the
    /// background, with nobody watching.
    func exchange(code: String, verifier: String) async throws {
        let response = try await postToken([
            "client_id": GoogleOAuthConfig.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": GoogleOAuthConfig.redirectURI,
        ])
        guard let scopes = response.scope?.split(separator: " ").map(String.init),
              scopes.contains(GoogleOAuthConfig.scope) else {
            // Google's consent screen lets people untick a scope; the sign-in "succeeds"
            // with nothing usable. Refuse it here rather than fail on the first write.
            throw GoogleAuthError.scopeNotGranted
        }
        guard let refresh = response.refreshToken else {
            throw GoogleAuthError.tokenRequestFailed(status: 200, detail: "no refresh_token in response")
        }
        CredentialKeychain.save(refresh, forKey: Self.refreshTokenKey)
        remember(response)
    }

    /// Forgets the sign-in on this device immediately, then revokes that same token at Google
    /// in the background (best effort: offline must not strand the person signed in). The
    /// token is captured first so a quick disconnect-then-reconnect can never have the late
    /// revoke wipe the NEW sign-in.
    func signOut() {
        let captured = CredentialKeychain.load(forKey: Self.refreshTokenKey)
        forgetLocally()
        guard let captured else { return }
        Task.detached { await Self.revoke(captured) }
    }

    private static func revoke(_ refresh: String) async {
        do {
            var req = URLRequest(url: GoogleOAuthConfig.revokeURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formBody(["token": refresh])
            _ = try await URLSession.shared.data(for: req)
        } catch {
            logger.error("Google revoke failed (already cleared on device): \(error.localizedDescription, privacy: .public)")
        }
    }

    func forgetLocally() {
        CredentialKeychain.save("", forKey: Self.refreshTokenKey)
        lock.lock()
        accessToken = nil
        accessTokenExpiry = nil
        lock.unlock()
    }

    // MARK: Private

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let scope: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", expiresIn = "expires_in"
            case refreshToken = "refresh_token", scope
        }
    }

    private func remember(_ response: TokenResponse) {
        lock.lock()
        accessToken = response.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        lock.unlock()
    }

    private func postToken(_ fields: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: GoogleOAuthConfig.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            if status == 400, detail.contains("invalid_grant") {
                forgetLocally()
                throw GoogleAuthError.accessRevoked
            }
            Self.logger.error("Google token request failed \(status): \(detail, privacy: .private)")
            throw GoogleAuthError.tokenRequestFailed(status: status, detail: detail)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }
}

// MARK: - Sign-in UI

/// Runs the system Google sign-in sheet. The browser session shares Safari's cookies
/// (`prefersEphemeralWebBrowserSession = false`) so someone already signed in to Google on
/// the phone does not have to type a password, which is most of the "easy" in this path.
@MainActor
final class GoogleSignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn() async throws {
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        var components = URLComponents(url: GoogleOAuthConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleOAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleOAuthConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfig.scope),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Always show the account chooser: someone with a work and a personal Google
            // account on the phone must be able to pick where their health data goes.
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: GoogleOAuthConfig.callbackScheme
            ) { url, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GoogleAuthError.cancelled)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? GoogleAuthError.badCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: GoogleAuthError.couldNotStart)
            }
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw GoogleAuthError.stateMismatch
        }
        if items.first(where: { $0.name == "error" })?.value == "access_denied" {
            throw GoogleAuthError.cancelled
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw GoogleAuthError.badCallback
        }
        try await GoogleTokenStore.shared.exchange(code: code, verifier: verifier)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
