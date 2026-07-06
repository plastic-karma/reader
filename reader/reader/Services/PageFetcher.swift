//
//  PageFetcher.swift
//  reader
//

import Foundation

/// One-shot download of a web page for the save-link snapshot. Unlike
/// FeedFetcher this validates the content type, caps the body size, follows
/// the redirect chain out to a final URL (the base for relative images), and
/// decodes the body's charset — none of which the feed path wants.
nonisolated struct PageFetcher: Sendable {

    struct FetchedPage: Sendable {
        let html: String
        /// URL after redirects; resolve relative image/link URLs against this.
        let finalURL: URL
    }

    enum FetchError: Error, LocalizedError, Equatable {
        case notHTTP
        case badStatus(Int)
        /// The response declared a non-HTML content type (the MIME type).
        case notHTML(String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notHTTP:
                return "Not an HTTP response"
            case .badStatus(let code):
                return "HTTP \(code)"
            case .notHTML(let mime):
                return "Not a web page (\(mime))"
            case .tooLarge:
                return "Page is too large to save"
            }
        }
    }

    /// Hard cap on the body; also bounds the cost of every regex pass
    /// downstream. 10 MB is far above real article pages.
    static let maxBytes = 10 * 1024 * 1024

    private static let allowedMIMETypes: Set<String> = ["text/html", "application/xhtml+xml"]

    private let session: URLSession

    init() {
        // Mirrors FeedFetcher: ephemeral, 30 s request timeout, same UA,
        // no URLCache (a snapshot is deliberately a point-in-time copy).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // The request timeout only fires on idle; the resource timeout is
        // the absolute budget for the whole page, so a dripping server
        // can't hold "Downloading…" open indefinitely.
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "reader/1.0 (macOS RSS reader)"]
        session = URLSession(configuration: configuration)
    }

    /// GET the page, validate status + content type + size, decode the
    /// charset. Redirects are followed by URLSession; the response's URL is
    /// surfaced as `finalURL`.
    func fetch(url: URL) async throws -> FetchedPage {
        var request = URLRequest(url: url)
        request.setValue(
            "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        // data(for:) like FeedFetcher — the declared-length pre-check
        // rejects honest oversize responses up front, the post-check catches
        // liars, and the resource timeout bounds how much a server can push
        // in the meantime.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.notHTTP
        }
        guard (200...299).contains(http.statusCode) else {
            throw FetchError.badStatus(http.statusCode)
        }
        // A missing/undeclared type is tolerated (misconfigured blogs);
        // extraction still degrades gracefully on non-HTML bytes.
        if let mime = http.mimeType?.lowercased(), !Self.allowedMIMETypes.contains(mime) {
            throw FetchError.notHTML(mime)
        }
        guard http.expectedContentLength <= Int64(Self.maxBytes),  // -1 (unknown) passes
              data.count <= Self.maxBytes else {
            throw FetchError.tooLarge
        }
        return FetchedPage(
            html: Self.decodeHTML(data: data, textEncodingName: http.textEncodingName),
            finalURL: http.url ?? url
        )
    }

    // MARK: - Charset (internal, unit-tested without network)

    /// Decode chain: response textEncodingName → <meta charset> scan of the
    /// first 2 KB → strict UTF-8 → lossy UTF-8 (never fails). A named
    /// encoding that fails to decode the bytes falls through to the next step.
    static func decodeHTML(data: Data, textEncodingName: String?) -> String {
        if let name = textEncodingName,
           let encoding = encoding(fromIANAName: name),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        if let name = metaCharsetName(in: data),
           let encoding = encoding(fromIANAName: name),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Charset name declared in a <meta charset="…"> or
    /// <meta http-equiv="content-type" content="text/html; charset=…"> tag
    /// within the first 2048 bytes (decoded as Latin-1, which preserves the
    /// ASCII the declaration is written in).
    static func metaCharsetName(in data: Data) -> String? {
        guard let prefix = String(data: data.prefix(2048), encoding: .isoLatin1) else {
            return nil
        }
        return HTMLProcessor.firstCapture(
            of: "<meta[^>]+charset\\s*=\\s*[\"']?([a-zA-Z0-9][a-zA-Z0-9._\\-]*)",
            in: prefix)
    }

    /// IANA name → String.Encoding; nil for unknown names. Internal because
    /// mail-header decoding shares it.
    static func encoding(fromIANAName name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
