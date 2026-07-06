//
//  MailHeaderDecoding.swift
//  reader
//

import Foundation

/// RFC 2047 "encoded-word" decoding for mail headers (Subject, From) plus
/// From-header display-name extraction. Provider-agnostic: Gmail's API
/// returns headers verbatim and IMAP ENVELOPE fields need the same
/// treatment. Regex/byte-scan based — headers are short single-line
/// strings, so no MIME library is warranted.
nonisolated enum MailHeaderDecoding {

    // =?charset?B|Q?payload?= — charset and payload never contain "?" or
    // whitespace, which keeps the scan linear and unambiguous.
    private static let encodedWordRegex = try! NSRegularExpression(
        pattern: "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?\\s]*)\\?=",
        options: []
    )

    /// Decodes every `=?charset?B|Q?payload?=` token in a header. Whitespace
    /// between two adjacent encoded words is dropped (RFC 2047 §6.2 — it
    /// exists only to satisfy line-length limits). Undecodable tokens
    /// (unknown charset, malformed payload) pass through verbatim rather
    /// than losing content.
    static func decodedHeader(_ raw: String) -> String {
        let ns = raw as NSString
        let matches = encodedWordRegex.matches(
            in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return raw }

        var result = ""
        var cursor = 0
        var previousDecoded = false
        for match in matches {
            let gap = ns.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor))
            let decoded = decodeEncodedWord(
                charset: ns.substring(with: match.range(at: 1)),
                encoding: ns.substring(with: match.range(at: 2)),
                payload: ns.substring(with: match.range(at: 3)))
            let dropGap = previousDecoded && decoded != nil
                && !gap.isEmpty && gap.allSatisfy(\.isWhitespace)
            if !dropGap {
                result += gap
            }
            result += decoded ?? ns.substring(with: match.range)
            previousDecoded = decoded != nil
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Display name of an address header: `Ben Thompson <ben@x.com>` →
    /// "Ben Thompson", `"Levine, Matt" <m@b.net>` → "Levine, Matt",
    /// a bare `ben@x.com` (or `<ben@x.com>` with no name) → the address.
    /// Encoded words in the name are decoded first.
    static func displayName(fromHeader raw: String) -> String {
        let decoded = decodedHeader(raw).trimmingCharacters(in: .whitespaces)
        guard let angle = decoded.range(of: "<", options: .backwards) else {
            return decoded
        }
        var name = String(decoded[..<angle.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .trimmingCharacters(in: .whitespaces)
        }
        if !name.isEmpty {
            return name
        }
        let address = decoded[angle.lowerBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        return address.isEmpty ? decoded : address
    }

    // MARK: - Encoded-word internals

    private static func decodeEncodedWord(
        charset: String,
        encoding: String,
        payload: String
    ) -> String? {
        let data: Data?
        switch encoding.uppercased() {
        case "B":
            data = base64Data(payload)
        case "Q":
            data = qDecodedData(payload)
        default:
            data = nil
        }
        guard let data else { return nil }
        return decode(data, charsetName: charset)
    }

    /// Base64 with tolerant re-padding — some mailers omit the trailing "=".
    private static func base64Data(_ payload: String) -> Data? {
        let remainder = payload.count % 4
        let padded = remainder == 0
            ? payload
            : payload + String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: padded)
    }

    /// Q encoding: "_" is space, "=HH" is a byte, everything else is a
    /// literal ASCII byte. Non-ASCII or a broken escape marks the word
    /// malformed (nil → verbatim passthrough).
    private static func qDecodedData(_ payload: String) -> Data? {
        guard payload.allSatisfy(\.isASCII) else { return nil }
        let ascii = Array(payload.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(ascii.count)
        var i = 0
        while i < ascii.count {
            switch ascii[i] {
            case UInt8(ascii: "_"):
                bytes.append(0x20)
                i += 1
            case UInt8(ascii: "="):
                guard i + 2 < ascii.count,
                      let hi = hexValue(ascii[i + 1]),
                      let lo = hexValue(ascii[i + 2]) else { return nil }
                bytes.append(hi << 4 | lo)
                i += 3
            default:
                bytes.append(ascii[i])
                i += 1
            }
        }
        return Data(bytes)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        default:
            return nil
        }
    }

    /// Named charset (strict) → strict UTF-8 → nil. No lossy fallback here:
    /// a token that can't be decoded faithfully is better shown encoded
    /// than as mojibake. RFC 2231 language suffixes ("utf-8*en") are stripped.
    private static func decode(_ data: Data, charsetName: String) -> String? {
        let name = charsetName.split(separator: "*").first.map(String.init) ?? charsetName
        if let encoding = PageFetcher.encoding(fromIANAName: name),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        return String(data: data, encoding: .utf8)
    }
}
