//
//  GoogleTokenProvider.swift
//  reader
//

import Foundation

/// Keychain-backed access-token supplier with a single-flight refresh:
/// refreshAll runs several newsletter feeds concurrently, and a cold start
/// must produce exactly one refresh grant, not one per feed.
actor GoogleTokenProvider: MailAuthorizing {

    /// Refresh this many seconds before Google's stated expiry so a token
    /// can't 401 mid-sync.
    static let expirySlack: TimeInterval = 60

    private let store: any TokenStoring
    private let transport: HTTPTransport
    /// Read at call time (not init) so a client ID pasted into Settings
    /// after launch is picked up without rebuilding the provider.
    private let clientID: @Sendable () -> String?

    private var cached: StoredTokens?
    private var refreshInFlight: Task<StoredTokens, any Error>?

    init(
        store: any TokenStoring,
        transport: @escaping HTTPTransport,
        clientID: @escaping @Sendable () -> String?
    ) {
        self.store = store
        self.transport = transport
        self.clientID = clientID
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let tokens = try loadTokens() else {
            throw MailProviderError.notSignedIn
        }
        if !forceRefresh, tokens.accessTokenExpiresAt > Date.now {
            return tokens.accessToken
        }
        return try await refreshedTokens(from: tokens).accessToken
    }

    private func loadTokens() throws -> StoredTokens? {
        if let cached {
            return cached
        }
        let loaded = try store.load()
        cached = loaded
        return loaded
    }

    private func refreshedTokens(from current: StoredTokens) async throws -> StoredTokens {
        if let refreshInFlight {
            return try await refreshInFlight.value
        }
        let task = Task { [store, transport, clientID] () throws -> StoredTokens in
            guard let clientID = clientID() else {
                throw MailProviderError.notSignedIn
            }
            let request = GoogleOAuthClient.refreshRequest(
                clientID: clientID,
                refreshToken: current.refreshToken)
            let (data, response) = try await transport(request)
            guard response.statusCode == 200 else {
                if let failure = try? JSONDecoder().decode(
                    GoogleOAuthClient.ErrorResponse.self, from: data),
                   failure.error == "invalid_grant" {
                    throw MailProviderError.authExpired
                }
                throw MailProviderError.http(response.statusCode)
            }
            guard let refreshed = try? JSONDecoder().decode(
                GoogleOAuthClient.TokenResponse.self, from: data) else {
                throw MailProviderError.invalidResponse("token refresh")
            }
            let updated = StoredTokens(
                accessToken: refreshed.accessToken,
                accessTokenExpiresAt: Date.now.addingTimeInterval(
                    TimeInterval(refreshed.expiresIn) - Self.expirySlack),
                refreshToken: refreshed.refreshToken ?? current.refreshToken)
            // Best-effort persist: a keychain hiccup shouldn't fail a sync
            // that already holds a valid token.
            try? store.save(updated)
            return updated
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        do {
            let updated = try await task.value
            cached = updated
            return updated
        } catch {
            // Keep the Keychain item on authExpired so Settings can
            // distinguish "session expired" from "never signed in", but drop
            // the memory cache: after a sign-out (store cleared elsewhere)
            // the next call must re-read the store and report notSignedIn
            // instead of replaying a stale token.
            cached = nil
            throw error
        }
    }
}
