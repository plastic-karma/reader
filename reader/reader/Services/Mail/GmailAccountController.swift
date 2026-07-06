//
//  GmailAccountController.swift
//  reader
//

import AppKit
import AuthenticationServices
import Foundation
import Observation

/// UserDefaults keys shared by the settings UI (@AppStorage) and the
/// nonisolated token plumbing. The client ID is configuration, not a
/// credential — only tokens live in the Keychain.
nonisolated enum MailAccountDefaults {
    static let clientIDKey = "gmailClientID"
    static let emailKey = "gmailAccountEmail"
}

extension GmailMailClient {
    /// Production wiring: Keychain-backed Google tokens over the shared
    /// URLSession transport. Side-effect-free until a call actually runs,
    /// so the refresh engine can hold one as an inline default.
    static func live() -> GmailMailClient {
        let transport = URLSessionHTTPTransport.make()
        return GmailMailClient(
            transport: transport,
            auth: GoogleTokenProvider(
                store: KeychainStore(),
                transport: transport,
                clientID: {
                    UserDefaults.standard.string(forKey: MailAccountDefaults.clientIDKey)
                }
            )
        )
    }
}

/// Main-actor facade for the Gmail account, mirroring LinkSaver and
/// RefreshScheduler: UI state lives here; tokens live in the Keychain and
/// the account email in UserDefaults, so the engine-side plumbing never
/// needs this object.
@MainActor
@Observable
final class GmailAccountController {

    enum Status: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String)
        case failed(String)
    }

    private(set) var status: Status = .signedOut

    private let store: any TokenStoring
    private let transport: HTTPTransport
    private let presentationContext = AuthPresentationContext()
    /// Retained for the duration of the browser flow; ASWebAuthenticationSession
    /// is cancelled by deallocation.
    private var activeSession: ASWebAuthenticationSession?

    init(store: any TokenStoring = KeychainStore(), transport: HTTPTransport? = nil) {
        self.store = store
        self.transport = transport ?? URLSessionHTTPTransport.make()
        restoreStatus()
    }

    /// Signed-in state survives relaunches: email in UserDefaults, tokens
    /// in the Keychain. Either missing means signed out.
    private func restoreStatus() {
        if let email = UserDefaults.standard.string(forKey: MailAccountDefaults.emailKey),
           (try? store.load()) ?? nil != nil {
            status = .signedIn(email: email)
        } else {
            status = .signedOut
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = status {
            return true
        }
        return false
    }

    // MARK: - Sign in

    func signIn() {
        guard status != .signingIn else { return }
        let clientID = UserDefaults.standard
            .string(forKey: MailAccountDefaults.clientIDKey) ?? ""
        guard let scheme = GoogleOAuthClient.redirectScheme(forClientID: clientID) else {
            status = .failed("Enter a valid iOS-type Google OAuth client ID first.")
            return
        }
        let pkce = GoogleOAuthClient.PKCE()
        let state = GoogleOAuthClient.randomURLSafeToken()
        guard let url = GoogleOAuthClient.authorizationURL(
            clientID: clientID, pkce: pkce, state: state) else {
            status = .failed("Could not build the Google sign-in URL.")
            return
        }

        status = .signingIn
        let session = ASWebAuthenticationSession(
            url: url,
            callback: .customScheme(scheme)
        ) { @Sendable [weak self] callbackURL, error in
            Task { @MainActor in
                await self?.completeSignIn(
                    callbackURL: callbackURL,
                    sessionError: error,
                    clientID: clientID,
                    verifier: pkce.verifier,
                    expectedState: state)
            }
        }
        session.presentationContextProvider = presentationContext
        // Reuse the user's existing Google browser session — they're signing
        // in to their own account, not a throwaway.
        session.prefersEphemeralWebBrowserSession = false
        activeSession = session
        session.start()
    }

    private func completeSignIn(
        callbackURL: URL?,
        sessionError: (any Error)?,
        clientID: String,
        verifier: String,
        expectedState: String
    ) async {
        activeSession = nil
        do {
            if let sessionError {
                if let authError = sessionError as? ASWebAuthenticationSessionError,
                   authError.code == .canceledLogin {
                    status = .signedOut
                    return
                }
                throw sessionError
            }
            guard let callbackURL else {
                throw GoogleOAuthClient.OAuthError.missingCode
            }
            let code = try GoogleOAuthClient.authorizationCode(
                fromCallback: callbackURL, expectedState: expectedState)
            let response = try await exchange(
                GoogleOAuthClient.tokenExchangeRequest(
                    clientID: clientID, code: code, verifier: verifier))
            guard let refreshToken = response.refreshToken else {
                throw GoogleOAuthClient.OAuthError.missingRefreshToken
            }
            try store.save(StoredTokens(
                accessToken: response.accessToken,
                accessTokenExpiresAt: Date.now.addingTimeInterval(
                    TimeInterval(response.expiresIn) - GoogleTokenProvider.expirySlack),
                refreshToken: refreshToken))
            let email = try await profileEmail(accessToken: response.accessToken)
            UserDefaults.standard.set(email, forKey: MailAccountDefaults.emailKey)
            status = .signedIn(email: email)
        } catch {
            status = .failed(shortDescription(of: error))
        }
    }

    private func exchange(_ request: URLRequest) async throws -> GoogleOAuthClient.TokenResponse {
        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else {
            let detail = (try? JSONDecoder().decode(
                GoogleOAuthClient.ErrorResponse.self, from: data))?.error
            throw GoogleOAuthClient.OAuthError.tokenExchangeFailed(
                detail ?? "HTTP \(response.statusCode)")
        }
        do {
            return try JSONDecoder().decode(GoogleOAuthClient.TokenResponse.self, from: data)
        } catch {
            throw GoogleOAuthClient.OAuthError.tokenExchangeFailed("unreadable token response")
        }
    }

    private struct Profile: Decodable {
        let emailAddress: String
    }

    /// users/me/profile is covered by any gmail scope — no extra openid
    /// scopes needed just to learn the address for the Settings row.
    private func profileEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: GmailMailClient.baseURL.appending(path: "profile"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        guard response.statusCode == 200,
              let profile = try? JSONDecoder().decode(Profile.self, from: data) else {
            throw GoogleOAuthClient.OAuthError.tokenExchangeFailed("could not read the account profile")
        }
        return profile.emailAddress
    }

    // MARK: - Sign out

    /// Best-effort revoke (the user may be offline), then clear local
    /// credentials. Newsletter feeds and their articles stay — deleting
    /// rules is a separate, explicit act; their next sync just reports
    /// "sign in required".
    func signOut() async {
        if let tokens = try? store.load() {
            _ = try? await transport(GoogleOAuthClient.revokeRequest(token: tokens.refreshToken))
        }
        try? store.clear()
        UserDefaults.standard.removeObject(forKey: MailAccountDefaults.emailKey)
        status = .signedOut
    }

    // MARK: - Rule testing

    /// Recent headers for a prospective rule — backs the rule sheet's Test
    /// button. 30 days mirrors the sync backfill window.
    func testHeaders(sender: String) async throws -> [MailMessageHeader] {
        try await GmailMailClient.live().messageHeaders(matching: MailQuery(
            sender: sender,
            since: Date.now.addingTimeInterval(-30 * 24 * 3600)))
    }

    private func shortDescription(of error: any Error) -> String {
        switch error {
        case let error as GoogleOAuthClient.OAuthError:
            return error.errorDescription ?? "Sign-in failed"
        case let error as MailProviderError:
            return error.errorDescription ?? "Gmail error"
        default:
            return error.localizedDescription
        }
    }
}

/// Anchors the ASWebAuthenticationSession sheet. Sign-in is user-initiated
/// from the Settings window, so the key window is the right anchor.
final class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
