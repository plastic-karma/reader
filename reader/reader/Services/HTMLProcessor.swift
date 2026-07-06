//
//  HTMLProcessor.swift
//  reader
//

import Foundation

/// Regex/string-based processing of feed HTML. This is defense in depth: the
/// reading pane's strict CSP is the real enforcement at render time (no
/// third-party HTML parser exists in this project).
nonisolated enum HTMLProcessor {

    // MARK: - Sanitizing

    /// Removes actively harmful elements (with their content), inline event
    /// handlers, and the responsive-image attributes that would let a renderer
    /// prefer a remote candidate over a rewritten `src`.
    static func sanitize(html: String) -> String {
        var result = html
        for element in ["script", "iframe", "object", "form"] {
            // Self-closing first, then open+content+close, then any stray tag.
            result = replacing(
                pattern: "<\(element)\\b[^>]*/\\s*>"
                    + "|<\(element)\\b[^>]*>.*?</\(element)\\s*>"
                    + "|</?\(element)\\b[^>]*>",
                in: result,
                with: "")
        }
        result = replacing(pattern: "</?embed\\b[^>]*>", in: result, with: "")
        result = transformingMatches(of: "<[a-zA-Z][^>]*>", in: result) { tag in
            replacing(pattern: eventHandlerAttributePattern, in: tag, with: "")
        }
        result = transformingMatches(of: imgTagPattern, in: result) { tag in
            replacing(pattern: "\\s+(?:srcset|sizes)\\s*=\\s*\(attributeValuePattern)", in: tag, with: "")
        }
        return result
    }

    // MARK: - Images

    /// Remote image URLs referenced by `<img>` tags, in document order,
    /// deduplicated. Prefers the lazy-load `data-src` over `src`, resolves
    /// relative values against `baseURL`, and keeps only http(s) results.
    static func extractImageURLs(html: String, baseURL: URL?) -> [URL] {
        var seen = Set<URL>()
        var urls: [URL] = []
        for tag in matches(of: imgTagPattern, in: html) {
            guard let url = imageSourceURL(inTag: tag, baseURL: baseURL) else { continue }
            if seen.insert(url).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    /// Rewrites each `<img>` whose resolved source appears in `mapping`
    /// (absolute remote URL string → local replacement, e.g.
    /// "reader-asset://<sha>.png") to load the local copy, dropping
    /// data-src/srcset/sizes so nothing can point back at the network.
    /// Unmapped tags and non-img content pass through untouched.
    static func rewriteImageSources(html: String, baseURL: URL?, mapping: [String: String]) -> String {
        guard !mapping.isEmpty else { return html }
        return transformingMatches(of: imgTagPattern, in: html) { tag in
            guard let url = imageSourceURL(inTag: tag, baseURL: baseURL),
                  let replacement = mapping[url.absoluteString] else {
                return tag
            }
            var rewritten = replacing(
                pattern: "\\s+(?:data-src|srcset|sizes)\\s*=\\s*\(attributeValuePattern)",
                in: tag,
                with: "")
            if attributeValue("src", inTag: rewritten) != nil {
                rewritten = replacing(
                    pattern: srcAttributePattern,
                    in: rewritten,
                    with: "src=\"\(NSRegularExpression.escapedTemplate(for: replacement))\"")
            } else {
                let closing = rewritten.hasSuffix("/>") ? "/>" : ">"
                var head = String(rewritten.dropLast(closing.count))
                while head.hasSuffix(" ") {
                    head.removeLast()
                }
                rewritten = head + " src=\"\(replacement)\"" + closing
            }
            return rewritten
        }
    }

    // MARK: - Entities

    /// Decodes numeric character references and a small table of common named
    /// entities (deliberately not exhaustive) in a single left-to-right pass,
    /// as the HTML spec requires: output is never re-scanned, so "&amp;lt;"
    /// becomes "&lt;" and "&#38;amp;" becomes "&amp;", never "<" or "&".
    static func decodeHTMLEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        return transformingMatches(of: "&(?:#(?:[xX][0-9a-fA-F]+|[0-9]+)|[a-zA-Z]+);", in: string) { reference in
            if reference.hasPrefix("&#") {
                let body = reference.dropFirst(2).dropLast()
                let value = body.hasPrefix("x") || body.hasPrefix("X")
                    ? UInt32(body.dropFirst(), radix: 16)
                    : UInt32(body)
                guard let value, let scalar = Unicode.Scalar(value) else { return reference }
                return String(Character(scalar))
            }
            return namedEntities[reference] ?? reference
        }
    }

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": "\u{00A0}", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}",
        "&hellip;": "\u{2026}", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
        "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}", "&copy;": "\u{00A9}",
        "&trade;": "\u{2122}", "&reg;": "\u{00AE}",
    ]

    // MARK: - Excerpts

    /// Plain-text excerpt of `html`: tags stripped (block boundaries become
    /// spaces so words don't fuse), entities decoded, whitespace collapsed,
    /// hard-truncated with a trailing ellipsis. `result.count <= maxLength`.
    static func plainTextExcerpt(from html: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        var text = replacing(pattern: blockBoundaryPattern, in: html, with: " ")
        text = replacing(pattern: "<[^>]+>", in: text, with: "")
        text = decodeHTMLEntities(text)
        text = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard text.count > maxLength else { return text }
        var head = String(text.prefix(maxLength - 1))
        while head.hasSuffix(" ") {
            head.removeLast()
        }
        return head + "…"
    }

    private static let blockBoundaryPattern =
        "<(?:(?:br|hr)\\b[^>]*"
        + "|/(?:p|div|section|article|aside|header|footer|main|h[1-6]|ul|ol|li|dl|dt|dd"
        + "|blockquote|pre|figure|figcaption|table|thead|tbody|tfoot|tr|td|th))\\s*>"

    // MARK: - Attribute helpers

    private static let imgTagPattern = "<img\\b[^>]*>"
    /// Double-quoted, single-quoted, or unquoted attribute value.
    private static let attributeValuePattern = "(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)"
    private static let eventHandlerAttributePattern = "\\s+on[a-zA-Z]+\\s*=\\s*" + attributeValuePattern
    /// `src` without matching the tail of `data-src`.
    private static let srcAttributePattern = "(?<![\\w-])src\\s*=\\s*" + attributeValuePattern

    /// The remote URL an `<img>` tag points at: lazy-load `data-src` wins over
    /// `src`, relative values resolve against `baseURL`, only http(s) counts.
    private static func imageSourceURL(inTag tag: String, baseURL: URL?) -> URL? {
        guard let raw = attributeValue("data-src", inTag: tag) ?? attributeValue("src", inTag: tag) else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func attributeValue(_ name: String, inTag tag: String) -> String? {
        let pattern = "(?<![\\w-])\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let match = compile(pattern).firstMatch(in: tag, range: fullRange(of: tag)) else {
            return nil
        }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) {
                return String(tag[range])
            }
        }
        return nil
    }

    // MARK: - Regex plumbing

    private static func compile(_ pattern: String) -> NSRegularExpression {
        // Patterns are fixed literals assembled above; a failure is programmer error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func fullRange(of string: String) -> NSRange {
        NSRange(string.startIndex..., in: string)
    }

    private static func replacing(pattern: String, in string: String, with template: String) -> String {
        compile(pattern).stringByReplacingMatches(in: string, range: fullRange(of: string), withTemplate: template)
    }

    private static func matches(of pattern: String, in string: String) -> [String] {
        compile(pattern).matches(in: string, range: fullRange(of: string)).compactMap { match in
            Range(match.range, in: string).map { String(string[$0]) }
        }
    }

    private static func transformingMatches(
        of pattern: String,
        in string: String,
        _ transform: (String) -> String
    ) -> String {
        let found = compile(pattern).matches(in: string, range: fullRange(of: string))
        guard !found.isEmpty else { return string }
        var result = ""
        var cursor = string.startIndex
        for match in found {
            guard let range = Range(match.range, in: string) else { continue }
            result += string[cursor..<range.lowerBound]
            result += transform(String(string[range]))
            cursor = range.upperBound
        }
        result += string[cursor...]
        return result
    }
}
