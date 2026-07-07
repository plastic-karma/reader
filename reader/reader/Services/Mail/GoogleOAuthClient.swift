//
//  GoogleOAuthClient.swift
//  reader
//

import CryptoKit
import Foundation
import Security

/// The pure half of Google sign-in: PKCE material, URL/request construction,
/// and callback parsing — everything unit-testable without a browser.
/// The interactive ASWebAuthenticationSession flow lives in
/// GmailAccountController. iOS-type OAuth clients are deliberately
/// secret-less: PKCE is the proof, so nothing here ever handles a client
/// secret.
nonisolated enum GoogleOAuthClient {

    static let scope = "https://www.googleapis.com/auth/gmail.modify"
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    private static let clientIDSuffix = ".apps.googleusercontent.com"

    enum OAuthError: Error, LocalizedError, Equatable {
        case userCancelled
        case stateMismatch
        case missingCode
        case tokenExchangeFailed(String)
        case missingRefreshToken

        var errorDescription: String? {
            switch self {
            case .userCancelled:
                return "Sign-in was cancelled."
            case .stateMismatch:
                return "Sign-in was rejected: callback state did not match."
            case .missingCode:
                return "Google did not return an authorization code."
            case .tokenExchangeFailed(let detail):
                return "Google sign-in failed: \(detail)"
            case .missingRefreshToken:
                return "Google didn't return a refresh token — remove this app's "
                    + "access at myaccount.google.com/permissions and sign in again."
            }
        }
    }

    // MARK: - Client ID → redirect scheme

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc".
    /// Google registers exactly this reversed custom scheme for iOS-type
    /// clients; nil for anything that doesn't look like such a client ID.
    static func redirectScheme(forClientID clientID: String) -> String? {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(clientIDSuffix) else { return nil }
        let prefix = trimmed.dropLast(clientIDSuffix.count)
        guard !prefix.isEmpty,
              prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return "com.googleusercontent.apps.\(prefix)"
    }

    static func redirectURI(forClientID clientID: String) -> String? {
        redirectScheme(forClientID: clientID).map { "\($0):/oauth2redirect" }
    }

    // MARK: - PKCE (RFC 7636, S256 only)

    struct PKCE: Sendable, Equatable {
        let verifier: String
        let challenge: String

        init() {
            self.init(verifier: GoogleOAuthClient.randomURLSafeToken())
        }

        /// Deterministic seam for the RFC 7636 Appendix B test vector.
        init(verifier: String) {
            self.verifier = verifier
            let digest = SHA256.hash(data: Data(verifier.utf8))
            challenge = GoogleOAuthClient.base64URLEncoded(Data(digest))
        }
    }

    /// 43-char base64url token from 32 CSPRNG bytes — used for the PKCE
    /// verifier and the `state` parameter.
    static func randomURLSafeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // Only fails when the system CSPRNG is unavailable; zeroed bytes
        // would still be a well-formed (if weak) token, and sign-in would
        // fail loudly at Google rather than corrupting anything locally.
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncoded(Data(bytes))
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorization request + callback

    static func authorizationURL(clientID: String, pkce: PKCE, state: String) -> URL? {
        guard let redirectURI = redirectURI(forClientID: clientID) else { return nil }
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url
    }

    static func authorizationCode(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") {
            throw error == "access_denied"
                ? OAuthError.userCancelled
                : OAuthError.tokenExchangeFailed(error)
        }
        guard value("state") == expectedState else {
            throw OAuthError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw OAuthError.missingCode
        }
        return code
    }

    // MARK: - Token endpoint

    struct TokenResponse: Decodable, Equatable {
        let accessToken: String
        let expiresIn: Int
        /// Present on the first exchange; absent on refreshes (Google keeps
        /// the original refresh token valid for installed apps).
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    struct ErrorResponse: Decodable, Equatable {
        let error: String
    }

    static func tokenExchangeRequest(clientID: String, code: String, verifier: String) -> URLRequest {
        formPOST(to: tokenEndpoint, fields: [
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI(forClientID: clientID) ?? ""),
        ])
    }

    static func refreshRequest(clientID: String, refreshToken: String) -> URLRequest {
        formPOST(to: tokenEndpoint, fields: [
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    static func revokeRequest(token: String) -> URLRequest {
        formPOST(to: revocationEndpoint, fields: [("token", token)])
    }

    private static func formPOST(to url: URL, fields: [(String, String)]) -> URLRequest {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }
}
