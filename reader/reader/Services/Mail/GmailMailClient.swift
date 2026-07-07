//
//  GmailMailClient.swift
//  reader
//

import Foundation

/// Gmail REST implementation of `MailProviderClient`. Construction is
/// side-effect-free (no Keychain or network I/O until a call runs), so the
/// refresh engine can hold one as an inline default. All HTTP goes through
/// the injected transport closure; all auth through `MailAuthorizing` —
/// tests script both.
nonisolated struct GmailMailClient: MailProviderClient, Sendable {

    let transport: HTTPTransport
    let auth: any MailAuthorizing

    static let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    /// Gmail's page maximum; 5 pages bounds a runaway rule (e.g. a bare
    /// domain matching thousands of messages) at 500 ids per sync.
    static let pageSize = 100
    static let maxPages = 5
    /// batchModify's documented per-call id limit.
    static let batchModifyChunk = 1000

    /// `after:` takes epoch seconds — second granularity and timezone-free,
    /// unlike its YYYY/MM/DD form.
    static func searchQuery(for query: MailQuery) -> String {
        "from:(\(query.sender)) after:\(Int(query.since.timeIntervalSince1970))"
    }

    // MARK: - MailProviderClient

    func messageHeaders(matching query: MailQuery) async throws -> [MailMessageHeader] {
        var ids: [String] = []
        var pageToken: String?
        for _ in 0..<Self.maxPages {
            var items = [
                URLQueryItem(name: "q", value: Self.searchQuery(for: query)),
                URLQueryItem(name: "maxResults", value: String(Self.pageSize)),
            ]
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let page = try GmailMessageParser.messageList(
                from: try await authorizedJSON(request(path: "messages", queryItems: items)))
            ids += (page.messages ?? []).map(\.id)
            guard let next = page.nextPageToken else { break }
            pageToken = next
        }

        // Sequential metadata fetches: typically 0–5 per sync, ≤500 on a
        // worst-case backfill, and the whole sync already runs inside
        // refreshAll's bounded concurrency window.
        var headers: [MailMessageHeader] = []
        headers.reserveCapacity(ids.count)
        for id in ids {
            let items = [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "Date"),
            ]
            headers.append(try GmailMessageParser.messageHeader(
                from: try await authorizedJSON(request(path: "messages/\(id)", queryItems: items))))
        }
        return headers
    }

    func message(id: String) async throws -> MailMessage {
        let items = [URLQueryItem(name: "format", value: "full")]
        return try GmailMessageParser.mailMessage(
            from: try await authorizedJSON(request(path: "messages/\(id)", queryItems: items)))
    }

    func markProcessed(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        var chunk = ids[...]
        while !chunk.isEmpty {
            let batch = Array(chunk.prefix(Self.batchModifyChunk))
            chunk = chunk.dropFirst(Self.batchModifyChunk)
            var modify = request(path: "messages/batchModify", queryItems: [])
            modify.httpMethod = "POST"
            modify.setValue("application/json", forHTTPHeaderField: "Content-Type")
            modify.httpBody = try JSONEncoder().encode(
                BatchModifyBody(ids: batch, removeLabelIds: ["INBOX", "UNREAD"]))
            _ = try await authorizedJSON(modify)
        }
    }

    private struct BatchModifyBody: Encodable {
        let ids: [String]
        let removeLabelIds: [String]
    }

    // MARK: - Plumbing

    private func request(path: String, queryItems: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(
            url: Self.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return URLRequest(url: components.url!)
    }

    /// Every Gmail call funnels through here: bearer header, one forced
    /// token refresh + retry on 401, then the shared status-code taxonomy.
    private func authorizedJSON(_ request: URLRequest) async throws -> Data {
        var authorized = request
        authorized.setValue(
            "Bearer \(try await auth.accessToken(forceRefresh: false))",
            forHTTPHeaderField: "Authorization")
        var (data, response) = try await transport(authorized)
        if response.statusCode == 401 {
            authorized.setValue(
                "Bearer \(try await auth.accessToken(forceRefresh: true))",
                forHTTPHeaderField: "Authorization")
            (data, response) = try await transport(authorized)
        }
        switch response.statusCode {
        case 200...299:
            return data
        case 401:
            throw MailProviderError.authExpired
        case 429:
            throw MailProviderError.rateLimited
        default:
            throw MailProviderError.http(response.statusCode)
        }
    }
}
