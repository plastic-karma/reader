//
//  MailProvider.swift
//  reader
//

import Foundation

/// Injectable HTTP seam for the mail layer (house pattern: a closure the
/// tests replace with scripted responses, no URLProtocol machinery).
typealias HTTPTransport =
    @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Production transport: ephemeral session (no shared cookies or cache),
/// 30 s request timeout, reader UA — mirrors FeedFetcher's configuration.
nonisolated enum URLSessionHTTPTransport {
    static func make() -> HTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "reader/1.0 (macOS RSS reader)"]
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MailProviderError.invalidResponse("not an HTTP response")
            }
            return (data, http)
        }
    }
}

/// Supplies a valid bearer token for mail API calls, refreshing when
/// needed. Implemented by GoogleTokenProvider; stubbed in tests.
nonisolated protocol MailAuthorizing: Sendable {
    /// A currently-valid access token. `forceRefresh` bypasses any cached
    /// token — the 401-retry path uses it after a rejected request.
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// What a newsletter sync asks its provider for.
nonisolated struct MailQuery: Sendable, Equatable {
    /// Provider-native sender match: Gmail `from:` operator semantics
    /// (address or domain token); IMAP will map this to SEARCH FROM.
    let sender: String
    /// Only messages received at or after this instant.
    let since: Date
}

nonisolated struct MailMessageHeader: Sendable, Equatable {
    /// Provider-scoped stable id (Gmail message id). Becomes Article.stableID.
    let id: String
    /// RFC 2047-decoded Subject; empty when the header is absent.
    let subject: String
    /// Decoded From display form, e.g. `Ben Thompson <ben@stratechery.com>`.
    let from: String
    /// internalDate (Gmail) / INTERNALDATE (IMAP); nil when unparseable.
    let date: Date?
    /// Still awaiting archive + mark-read (Gmail: labelIds contains INBOX).
    /// Drives archive self-healing; false for already-processed messages.
    let isUnprocessed: Bool
}

nonisolated struct MailMessage: Sendable {
    let header: MailMessageHeader
    /// Decoded, charset-resolved HTML body; nil for text-only messages.
    let bodyHTML: String?
    /// Decoded text/plain body; nil when absent.
    let bodyText: String?
}

/// One mailbox provider (Gmail REST now, IMAP later). Sender filtering is
/// the provider's job — both protocols support it natively. Subject-regex
/// filtering is deliberately NOT: it runs client-side in the sync so every
/// provider behaves identically.
nonisolated protocol MailProviderClient: Sendable {
    /// Headers of messages matching `query`. Includes already-processed
    /// (archived) messages — dedupe and archive self-healing both depend
    /// on that. Order is provider-defined.
    func messageHeaders(matching query: MailQuery) async throws -> [MailMessageHeader]
    /// Full body for one id from a previous messageHeaders call.
    func message(id: String) async throws -> MailMessage
    /// Archive + mark read. Idempotent; an empty `ids` must be a no-op
    /// with no network traffic.
    func markProcessed(ids: [String]) async throws
}

nonisolated enum MailProviderError: Error, LocalizedError, Equatable {
    /// No stored credentials at all.
    case notSignedIn
    /// The refresh token was rejected (revoked or expired grant).
    case authExpired
    /// The rule itself is unusable (bad subject regex, empty sender).
    case invalidRule(String)
    case rateLimited
    case http(Int)
    /// Undecodable JSON or a response missing required fields.
    case invalidResponse(String)

    /// Short strings sized for `feed.lastError` and its sidebar tooltip.
    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Gmail: sign in required (Settings → Newsletters)"
        case .authExpired:
            return "Gmail: session expired — sign in again in Settings"
        case .invalidRule(let reason):
            return reason
        case .rateLimited:
            return "Gmail: rate limited — will retry next refresh"
        case .http(let code):
            return "Gmail: HTTP \(code)"
        case .invalidResponse(let detail):
            return "Gmail: unexpected response (\(detail))"
        }
    }
}
