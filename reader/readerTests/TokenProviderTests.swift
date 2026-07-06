//
//  TokenProviderTests.swift
//  readerTests
//

import XCTest
@testable import reader

final class TokenProviderTests: XCTestCase {

    // MARK: - Doubles

    private final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: StoredTokens?

        init(_ initial: StoredTokens? = nil) {
            tokens = initial
        }

        func load() throws -> StoredTokens? {
            lock.withLock { tokens }
        }

        func save(_ new: StoredTokens) throws {
            lock.withLock { tokens = new }
        }

        func clear() throws {
            lock.withLock { tokens = nil }
        }
    }

    /// Answers every request with the same canned response (after an
    /// optional delay, for the single-flight race) and counts calls.
    private actor TokenTransport {
        private let status: Int
        private let responseBody: String
        private let delayMilliseconds: Int
        private(set) var requests: [URLRequest] = []

        init(status: Int, body: String, delayMilliseconds: Int = 0) {
            self.status = status
            responseBody = body
            self.delayMilliseconds = delayMilliseconds
        }

        func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            if delayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (Data(responseBody.utf8), response)
        }
    }

    private let refreshSuccess = #"{"access_token": "fresh-token", "expires_in": 3600, "token_type": "Bearer"}"#
    private let invalidGrant = #"{"error": "invalid_grant", "error_description": "Token has been revoked."}"#

    private func expiredTokens() -> StoredTokens {
        StoredTokens(
            accessToken: "stale-token",
            accessTokenExpiresAt: Date.now.addingTimeInterval(-10),
            refreshToken: "rt-original")
    }

    private func freshTokens() -> StoredTokens {
        StoredTokens(
            accessToken: "live-token",
            accessTokenExpiresAt: Date.now.addingTimeInterval(3600),
            refreshToken: "rt-original")
    }

    private func makeProvider(
        store: InMemoryTokenStore,
        transport: TokenTransport,
        clientID: String? = "123-abc.apps.googleusercontent.com"
    ) -> GoogleTokenProvider {
        GoogleTokenProvider(
            store: store,
            transport: { try await transport.handle($0) },
            clientID: { clientID })
    }

    // MARK: - Tests

    func testUnexpiredTokenIsReturnedWithoutNetwork() async throws {
        let transport = TokenTransport(status: 200, body: refreshSuccess)
        let provider = makeProvider(store: InMemoryTokenStore(freshTokens()), transport: transport)

        let token = try await provider.accessToken(forceRefresh: false)

        XCTAssertEqual(token, "live-token")
        let calls = await transport.requests.count
        XCTAssertEqual(calls, 0)
    }

    func testExpiredTokenRefreshesOnceAndPersists() async throws {
        let store = InMemoryTokenStore(expiredTokens())
        let transport = TokenTransport(status: 200, body: refreshSuccess)
        let provider = makeProvider(store: store, transport: transport)

        let token = try await provider.accessToken(forceRefresh: false)

        XCTAssertEqual(token, "fresh-token")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let form = String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=rt-original"))

        let persisted = try XCTUnwrap(try store.load())
        XCTAssertEqual(persisted.accessToken, "fresh-token")
        XCTAssertEqual(
            persisted.refreshToken, "rt-original",
            "Google omits refresh_token on refresh — the original must survive")
        XCTAssertTrue(persisted.accessTokenExpiresAt > Date.now.addingTimeInterval(3000))
    }

    func testForceRefreshBypassesUnexpiredToken() async throws {
        let transport = TokenTransport(status: 200, body: refreshSuccess)
        let provider = makeProvider(store: InMemoryTokenStore(freshTokens()), transport: transport)

        let token = try await provider.accessToken(forceRefresh: true)

        XCTAssertEqual(token, "fresh-token")
        let calls = await transport.requests.count
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentForcedRefreshesSingleFlight() async throws {
        let transport = TokenTransport(status: 200, body: refreshSuccess, delayMilliseconds: 50)
        let provider = makeProvider(store: InMemoryTokenStore(expiredTokens()), transport: transport)

        async let first = provider.accessToken(forceRefresh: true)
        async let second = provider.accessToken(forceRefresh: true)
        let tokens = try await (first, second)

        XCTAssertEqual(tokens.0, "fresh-token")
        XCTAssertEqual(tokens.1, "fresh-token")
        let calls = await transport.requests.count
        XCTAssertEqual(calls, 1, "Two concurrent callers must share one refresh grant")
    }

    func testInvalidGrantThrowsAuthExpiredAndKeepsStoredTokens() async throws {
        let store = InMemoryTokenStore(expiredTokens())
        let transport = TokenTransport(status: 400, body: invalidGrant)
        let provider = makeProvider(store: store, transport: transport)

        do {
            _ = try await provider.accessToken(forceRefresh: false)
            XCTFail("Expected authExpired")
        } catch {
            XCTAssertEqual(error as? MailProviderError, .authExpired)
        }
        XCTAssertNotNil(
            try store.load(),
            "Keychain item survives so Settings can say 'expired', not 'never signed in'")
    }

    func testNonGrantServerErrorMapsToHTTP() async {
        let transport = TokenTransport(status: 503, body: "oops")
        let provider = makeProvider(store: InMemoryTokenStore(expiredTokens()), transport: transport)

        do {
            _ = try await provider.accessToken(forceRefresh: false)
            XCTFail("Expected http error")
        } catch {
            XCTAssertEqual(error as? MailProviderError, .http(503))
        }
    }

    func testEmptyStoreThrowsNotSignedInWithoutNetwork() async {
        let transport = TokenTransport(status: 200, body: refreshSuccess)
        let provider = makeProvider(store: InMemoryTokenStore(), transport: transport)

        do {
            _ = try await provider.accessToken(forceRefresh: false)
            XCTFail("Expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? MailProviderError, .notSignedIn)
        }
        let calls = await transport.requests.count
        XCTAssertEqual(calls, 0)
    }

    func testMissingClientIDThrowsNotSignedIn() async {
        let transport = TokenTransport(status: 200, body: refreshSuccess)
        let provider = makeProvider(
            store: InMemoryTokenStore(expiredTokens()),
            transport: transport,
            clientID: nil)

        do {
            _ = try await provider.accessToken(forceRefresh: false)
            XCTFail("Expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? MailProviderError, .notSignedIn)
        }
    }

    func testSignOutMidSessionIsReportedAsNotSignedInNextCall() async throws {
        let store = InMemoryTokenStore(expiredTokens())
        let transport = TokenTransport(status: 400, body: invalidGrant)
        let provider = makeProvider(store: store, transport: transport)

        _ = try? await provider.accessToken(forceRefresh: false)
        try store.clear()

        do {
            _ = try await provider.accessToken(forceRefresh: false)
            XCTFail("Expected notSignedIn after the store was cleared")
        } catch {
            XCTAssertEqual(
                error as? MailProviderError, .notSignedIn,
                "A failed refresh must drop the memory cache so sign-out is honored")
        }
    }
}
