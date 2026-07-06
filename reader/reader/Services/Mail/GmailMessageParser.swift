//
//  GmailMessageParser.swift
//  reader
//

import Foundation

/// Pure decoding of Gmail API JSON into the neutral mail types — no
/// networking, fully unit-testable with string fixtures. Gmail has already
/// undone the wire transfer encoding (quoted-printable/base64), so a part's
/// `body.data` is base64url of the content bytes in the part's declared
/// charset.
nonisolated enum GmailMessageParser {

    // MARK: - DTOs (verbatim Gmail JSON shapes)

    struct MessageList: Decodable {
        struct Ref: Decodable {
            let id: String
        }
        /// Absent (not empty) when a page has no results.
        let messages: [Ref]?
        let nextPageToken: String?
    }

    struct Message: Decodable {
        let id: String
        let labelIds: [String]?
        /// Epoch **milliseconds** as a string.
        let internalDate: String?
        let payload: Part?
    }

    struct Part: Decodable {
        let mimeType: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?
    }

    struct Header: Decodable {
        let name: String
        let value: String
    }

    struct Body: Decodable {
        let data: String?
        let size: Int?
    }

    // MARK: - Entry points

    /// Decodes a `messages.list` page.
    static func messageList(from data: Data) throws -> MessageList {
        try decode(MessageList.self, from: data, context: "message list")
    }

    /// Decodes a `messages.get?format=metadata` response into a header.
    static func messageHeader(from data: Data) throws -> MailMessageHeader {
        try messageHeader(of: decode(Message.self, from: data, context: "message metadata"))
    }

    /// Decodes a `messages.get?format=full` response into header + bodies.
    static func mailMessage(from data: Data) throws -> MailMessage {
        let message = try decode(Message.self, from: data, context: "message")
        let leaves = message.payload.map(bodyParts(in:))
        return MailMessage(
            header: messageHeader(of: message),
            bodyHTML: leaves?.html.flatMap(decodedBody(of:)),
            bodyText: leaves?.plain.flatMap(decodedBody(of:))
        )
    }

    static func messageHeader(of message: Message) -> MailMessageHeader {
        let subject = header("Subject", in: message).map(MailHeaderDecoding.decodedHeader) ?? ""
        let from = header("From", in: message).map(MailHeaderDecoding.decodedHeader) ?? ""
        // internalDate is the arrival time Gmail sorts by; the Date header
        // is a sender-supplied fallback for the odd message without one.
        let date = message.internalDate.flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? header("Date", in: message).flatMap(FeedDates.parse)
        return MailMessageHeader(
            id: message.id,
            subject: subject,
            from: from,
            date: date,
            isUnprocessed: (message.labelIds ?? []).contains("INBOX")
        )
    }

    // MARK: - Reader mapping

    /// Cap on the HTML body handed to the sanitize/render pipeline; beyond
    /// it we fall back to the plain part, then to a stub. Far above real
    /// newsletters, which top out around a few hundred KB.
    static let maxBodyBytes = 2 * 1024 * 1024

    /// Maps a fetched message onto the shape `RefreshEngine.prepare`
    /// already understands. Never fails: a message with no readable body
    /// becomes a stub linking back to Gmail.
    static func parsedItem(from message: MailMessage, maxBodyBytes: Int = maxBodyBytes) -> ParsedItem {
        let header = message.header
        let content: String
        if let html = message.bodyHTML, html.utf8.count <= maxBodyBytes {
            content = html
        } else if let text = message.bodyText, text.utf8.count <= maxBodyBytes {
            content = htmlFromPlainText(text)
        } else {
            let target = permalink(id: header.id)?.absoluteString ?? "https://mail.google.com"
            content = "<p>This message has no readable body. "
                + "<a href=\"\(target)\">Open in Gmail</a></p>"
        }
        return ParsedItem(
            stableID: header.id,
            title: header.subject.isEmpty ? "(no subject)" : header.subject,
            author: authorName(fromHeader: header.from),
            link: permalink(id: header.id),
            publishedAt: header.date,
            summaryHTML: nil,
            contentHTML: content
        )
    }

    /// Gmail web UI permalink — API message ids are the UI's hex ids.
    static func permalink(id: String) -> URL? {
        URL(string: "https://mail.google.com/mail/#all/\(id)")
    }

    /// Escaped, paragraph-ized HTML for text-only newsletters. No
    /// linkification — the sanitize pipeline downstream expects markup it
    /// can trust, and plain text stays plain.
    static func htmlFromPlainText(_ text: String) -> String {
        // Mail bodies are CRLF-delimited on the wire; normalize before the
        // blank-line scan or every "empty" line would still hold a \r.
        let paragraphs = escapeHTML(text.replacingOccurrences(of: "\r\n", with: "\n"))
            .components(separatedBy: "\n")
            .split(separator: "", omittingEmptySubsequences: true)
            .map { "<p>" + $0.joined(separator: "<br>") + "</p>" }
        return paragraphs.isEmpty ? "<p></p>" : paragraphs.joined()
    }

    // MARK: - Body decoding

    /// First text/html and text/plain leaves of the MIME tree, depth-first.
    /// A single-part message is its own leaf. Strict RFC 2046 prefers the
    /// *last* alternative; first-html-in-DFS is what mail clients render
    /// for real newsletters and keeps the walk trivial.
    static func bodyParts(in root: Part) -> (html: Part?, plain: Part?) {
        var html: Part?
        var plain: Part?
        visit(root) { part in
            guard part.body?.data != nil, let mime = part.mimeType?.lowercased() else { return }
            if html == nil, mime.hasPrefix("text/html") {
                html = part
            } else if plain == nil, mime.hasPrefix("text/plain") {
                plain = part
            }
        }
        return (html, plain)
    }

    private static func visit(_ part: Part, _ body: (Part) -> Void) {
        body(part)
        for child in part.parts ?? [] {
            visit(child, body)
        }
    }

    /// base64url-decode a part and resolve its charset through the same
    /// tested cascade saved pages use (IANA name → strict UTF-8 → lossy).
    static func decodedBody(of part: Part) -> String? {
        guard let encoded = part.body?.data,
              let data = data(base64URLEncoded: encoded) else { return nil }
        return PageFetcher.decodeHTML(data: data, textEncodingName: charset(of: part))
    }

    /// Charset declared on the part's own Content-Type header, if any.
    static func charset(of part: Part) -> String? {
        guard let contentType = part.headers?
            .first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?
            .value else { return nil }
        return HTMLProcessor.firstCapture(
            of: "charset\\s*=\\s*\"?([A-Za-z0-9._\\-]+)",
            in: contentType)
    }

    /// Gmail's base64url: `-`/`_` alphabet, padding usually omitted.
    static func data(base64URLEncoded string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    // MARK: - Helpers

    private static func header(_ name: String, in message: Message) -> String? {
        message.payload?.headers?
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?
            .value
    }

    private static func authorName(fromHeader from: String) -> String? {
        guard !from.isEmpty else { return nil }
        return MailHeaderDecoding.displayName(fromHeader: from)
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        context: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MailProviderError.invalidResponse(context)
        }
    }
}
