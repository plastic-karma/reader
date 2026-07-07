//
//  GmailMailClientTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class GmailMailClientTests: XCTestCase {

    // MARK: - Test doubles (house pattern: scripted seams, no URLProtocol)

    /// Serves canned (status, body) exchanges in order and records every
    /// request the client sends.
    private actor TransportScript {
        struct Exchange {
            let status: Int
            let body: String
        }

        private var queue: [Exchange]
        private(set) var requests: [URLRequest] = []

        init(_ exchanges: [Exchange]) {
            queue = exchanges
        }

        func exchange(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !queue.isEmpty else {
                XCTFail("Unexpected request beyond script: \(request.url?.absoluteString ?? "?")")
                throw URLError(.badServerResponse)
            }
            let next = queue.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: next.status,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (Data(next.body.utf8), response)
        }
    }

    /// Hands out tokens in order (the last one repeats) and records the
    /// forceRefresh flag of every call.
    private actor AuthScript: MailAuthorizing {
        private var tokens: [String]
        private(set) var forceFlags: [Bool] = []

        init(tokens: [String]) {
            self.tokens = tokens
        }

        func accessToken(forceRefresh: Bool) async throws -> String {
            forceFlags.append(forceRefresh)
            guard let first = tokens.first else {
                throw MailProviderError.notSignedIn
            }
            if tokens.count > 1 {
                tokens.removeFirst()
                return first
            }
            return first
        }
    }

    private func makeClient(
        script: [TransportScript.Exchange],
        tokens: [String] = ["tok"]
    ) -> (GmailMailClient, TransportScript, AuthScript) {
        let transport = TransportScript(script)
        let auth = AuthScript(tokens: tokens)
        let client = GmailMailClient(
            transport: { try await transport.exchange($0) },
            auth: auth)
        return (client, transport, auth)
    }

    private func metadataJSON(id: String, inbox: Bool) -> String {
        let labels = inbox ? #""INBOX", "UNREAD""# : #""CATEGORY_UPDATES""#
        return #"""
        {
          "id": "\#(id)",
          "labelIds": [\#(labels)],
          "internalDate": "1751791234567",
          "payload": {
            "mimeType": "text/html",
            "headers": [
              {"name": "Subject", "value": "Subject \#(id)"},
              {"name": "From", "value": "N <n@x.com>"}
            ],
            "body": {"size": 0}
          }
        }
        """#
    }

    private let query = MailQuery(
        sender: "news@example.com",
        since: Date(timeIntervalSince1970: 1_700_000_000))

    // MARK: - Query construction

    func testSearchQueryUsesFromOperatorAndEpochAfter() {
        XCTAssertEqual(
            GmailMailClient.searchQuery(for: query),
            "from:(news@example.com) after:1700000000")
    }

    // MARK: - messageHeaders

    func testHeadersPaginateAndCarryLabelState() async throws {
        let (client, transport, _) = makeClient(script: [
            .init(status: 200, body: GmailFixtures.listPageOne),
            .init(status: 200, body: GmailFixtures.listPageTwo),
            .init(status: 200, body: metadataJSON(id: "m1", inbox: true)),
            .init(status: 200, body: metadataJSON(id: "m2", inbox: false)),
            .init(status: 200, body: metadataJSON(id: "m3", inbox: true)),
        ])

        let headers = try await client.messageHeaders(matching: query)

        XCTAssertEqual(headers.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(headers.map(\.isUnprocessed), [true, false, true])

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        let firstQuery = try XCTUnwrap(requests[0].url?.query(percentEncoded: false))
        XCTAssertTrue(firstQuery.contains("q=from:(news@example.com) after:1700000000"))
        XCTAssertTrue(firstQuery.contains("maxResults=100"))
        XCTAssertFalse(firstQuery.contains("pageToken"))
        let secondQuery = try XCTUnwrap(requests[1].url?.query(percentEncoded: false))
        XCTAssertTrue(secondQuery.contains("pageToken=page2"))
    }

    func testMetadataRequestAsksForExactlyTheNeededHeaders() async throws {
        let (client, transport, _) = makeClient(script: [
            .init(status: 200, body: GmailFixtures.listPageTwo),
            .init(status: 200, body: metadataJSON(id: "m3", inbox: true)),
        ])

        _ = try await client.messageHeaders(matching: query)

        let requests = await transport.requests
        let metadataQuery = try XCTUnwrap(requests[1].url?.query(percentEncoded: false))
        XCTAssertTrue(metadataQuery.contains("format=metadata"))
        XCTAssertTrue(metadataQuery.contains("metadataHeaders=Subject"))
        XCTAssertTrue(metadataQuery.contains("metadataHeaders=From"))
        XCTAssertTrue(metadataQuery.contains("metadataHeaders=Date"))
        XCTAssertTrue(
            try XCTUnwrap(requests[1].url?.path()).hasSuffix("/messages/m3"))
    }

    func testEmptyResultPageYieldsNoHeadersAndNoMetadataFetches() async throws {
        let (client, transport, _) = makeClient(script: [
            .init(status: 200, body: GmailFixtures.listEmpty),
        ])

        let headers = try await client.messageHeaders(matching: query)

        XCTAssertTrue(headers.isEmpty)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    // MARK: - message

    func testMessageFetchesFullFormat() async throws {
        let (client, transport, _) = makeClient(script: [
            .init(status: 200, body: GmailFixtures.fullMultipartAlternative),
        ])

        let message = try await client.message(id: "full1")

        XCTAssertEqual(message.header.id, "full1")
        XCTAssertNotNil(message.bodyHTML)
        let requests = await transport.requests
        let url = try XCTUnwrap(requests.first?.url)
        XCTAssertTrue(url.path().hasSuffix("/messages/full1"))
        XCTAssertEqual(url.query(percentEncoded: false), "format=full")
    }

    // MARK: - 401 retry + error taxonomy

    func testA401TriggersOneForcedRefreshAndRetry() async throws {
        let (client, transport, auth) = makeClient(
            script: [
                .init(status: 401, body: "{}"),
                .init(status: 200, body: GmailFixtures.listEmpty),
            ],
            tokens: ["stale", "fresh"])

        _ = try await client.messageHeaders(matching: query)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer stale")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        let flags = await auth.forceFlags
        XCTAssertEqual(flags, [false, true])
    }

    func testA401AfterForcedRefreshThrowsAuthExpired() async {
        let (client, _, _) = makeClient(
            script: [
                .init(status: 401, body: "{}"),
                .init(status: 401, body: "{}"),
            ],
            tokens: ["stale", "fresh"])

        do {
            _ = try await client.messageHeaders(matching: query)
            XCTFail("Expected authExpired")
        } catch {
            XCTAssertEqual(error as? MailProviderError, .authExpired)
        }
    }

    func testRateLimitAndServerErrorsMapToTaxonomy() async {
        for (status, expected) in [(429, MailProviderError.rateLimited), (500, .http(500))] {
            let (client, _, _) = makeClient(script: [.init(status: status, body: "")])
            do {
                _ = try await client.messageHeaders(matching: query)
                XCTFail("Expected error for \(status)")
            } catch {
                XCTAssertEqual(error as? MailProviderError, expected)
            }
        }
    }

    // MARK: - markProcessed

    private struct BatchBody: Decodable {
        let ids: [String]
        let removeLabelIds: [String]
    }

    func testBatchModifySendsArchiveAndReadRemoval() async throws {
        let (client, transport, _) = makeClient(script: [
            .init(status: 204, body: ""),
        ])

        try await client.markProcessed(ids: ["a", "b"])

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(try XCTUnwrap(request.url?.path()).hasSuffix("/messages/batchModify"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONDecoder().decode(BatchBody.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body.ids, ["a", "b"])
        XCTAssertEqual(body.removeLabelIds, ["INBOX", "UNREAD"])
    }

    func testBatchModifyChunksAtLimit() async throws {
        let (client, transport, _) = makeClient(script: [
            .init(status: 204, body: ""),
            .init(status: 204, body: ""),
        ])
        let ids = (0..<1200).map { "id\($0)" }

        try await client.markProcessed(ids: ids)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let first = try JSONDecoder().decode(BatchBody.self, from: XCTUnwrap(requests[0].httpBody))
        let second = try JSONDecoder().decode(BatchBody.self, from: XCTUnwrap(requests[1].httpBody))
        XCTAssertEqual(first.ids.count, 1000)
        XCTAssertEqual(second.ids.count, 200)
        XCTAssertEqual(first.ids.first, "id0")
        XCTAssertEqual(second.ids.last, "id1199")
    }

    func testEmptyIDsMakeNoNetworkCalls() async throws {
        let (client, transport, auth) = makeClient(script: [])

        try await client.markProcessed(ids: [])

        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 0)
        let authCalls = await auth.forceFlags.count
        XCTAssertEqual(authCalls, 0)
    }
}
