//
//  FeedFetcher.swift
//  reader
//

import Foundation

/// Downloads feed documents with conditional-GET support so unchanged feeds
/// cost one cheap 304 round-trip instead of a full body.
nonisolated struct FeedFetcher: Sendable {

    enum FetchResult: Sendable {
        case notModified
        case fetched(data: Data, etag: String?, lastModified: String?)
    }

    enum FetchError: Error, LocalizedError {
        case notHTTP
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notHTTP:
                return "Not an HTTP response"
            case .badStatus(let code):
                return "HTTP \(code)"
            }
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // Conditional-GET state lives in the Feed model, not URLCache.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "reader/1.0 (macOS RSS reader)"]
        session = URLSession(configuration: configuration)
    }

    func fetch(url: URL, etag: String?, lastModified: String?) async throws -> FetchResult {
        var request = URLRequest(url: url)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.notHTTP
        }
        switch http.statusCode {
        case 304:
            return .notModified
        case 200...299:
            return .fetched(
                data: data,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
        default:
            throw FetchError.badStatus(http.statusCode)
        }
    }
}
