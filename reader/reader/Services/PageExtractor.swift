//
//  PageExtractor.swift
//  reader
//

import Foundation

/// Reader-style extraction of a full web page's main content, regex-over-
/// string in HTMLProcessor's house style (no DOM parser). Input must already
/// be sanitized (HTMLProcessor.sanitize): with <script>/<iframe> bodies gone,
/// tag-shaped strings inside JS can no longer derail the block regexes.
nonisolated enum PageExtractor {

    struct ExtractedPage {
        /// og:title → <title> → source URL host; entity-decoded,
        /// whitespace-collapsed, never empty.
        let title: String
        /// Body fragment for the reading pane (still needs the image
        /// cache/rewrite pass; already stripped of style/link/noscript/comments).
        let contentHTML: String
    }

    /// Minimum visible text for an <article>/<main> candidate. Teaser cards,
    /// comment stubs, and a nested-<article> truncation artifact all fail this
    /// gate and fall through to the next tier.
    static let minimumCandidateTextLength = 200

    static func extract(fromSanitizedHTML html: String, sourceURL: URL) -> ExtractedPage {
        ExtractedPage(
            title: title(inHTML: html, sourceURL: sourceURL),
            contentHTML: mainContent(inHTML: html)
        )
    }

    // MARK: - Title

    /// Precedence: og:title meta → <title> → sourceURL host → absoluteString.
    static func title(inHTML html: String, sourceURL: URL) -> String {
        if let title = metaOGTitle(inHTML: html) {
            return title
        }
        if let title = titleTagText(inHTML: html) {
            return title
        }
        return sourceURL.host() ?? sourceURL.absoluteString
    }

    /// The "content" of the first <meta> whose property *or* name is
    /// "og:title" (some sites use name=); nil when absent or empty.
    private static func metaOGTitle(inHTML html: String) -> String? {
        for tag in HTMLProcessor.matches(of: "<meta\\b[^>]*>", in: html) {
            let kind = HTMLProcessor.attributeValue("property", inTag: tag)
                ?? HTMLProcessor.attributeValue("name", inTag: tag)
            guard kind?.lowercased() == "og:title",
                  let content = HTMLProcessor.attributeValue("content", inTag: tag) else {
                continue
            }
            let title = collapseWhitespace(HTMLProcessor.decodeHTMLEntities(content))
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private static func titleTagText(inHTML html: String) -> String? {
        guard let raw = HTMLProcessor.firstCapture(of: "<title\\b[^>]*>(.*?)</title\\s*>", in: html) else {
            return nil
        }
        let title = collapseWhitespace(HTMLProcessor.decodeHTMLEntities(raw))
        return title.isEmpty ? nil : title
    }

    // MARK: - Content

    /// Tier 1: first <article> block — accepted only past the text gate.
    /// Tier 2: first <main> block    — same gate.
    /// Tier 3: <body> content with <header>/<nav>/<footer>/<aside> stripped
    ///         (no gate; last resort). No <body>: the whole input, stripped.
    static func mainContent(inHTML html: String) -> String {
        for element in ["article", "main"] {
            if let candidate = candidate(element: element, inHTML: html) {
                let cleaned = cleanedFragment(candidate)
                if hasEnoughText(cleaned) {
                    return cleaned
                }
            }
        }
        return cleanedFragment(strippedBody(ofHTML: html))
    }

    /// Non-greedy: stops at the FIRST closing tag. Chosen deliberately —
    /// sibling <article>s (per-comment, per-teaser) are far more common than
    /// nested ones, and greedy would swallow everything between the first
    /// open and the LAST close. The text gate mops up the two non-greedy
    /// failure shapes (truncated-at-nested-close, teaser-first).
    private static func candidate(element: String, inHTML html: String) -> String? {
        HTMLProcessor.firstCapture(of: "<\(element)\\b[^>]*>(.*?)</\(element)\\s*>", in: html)
    }

    /// <body> content (tolerating an unclosed body), else the whole input,
    /// with page chrome removed. Chrome stripping happens only at this tier:
    /// semantic blogs put the <h1> inside <article><header>, which tiers 1–2
    /// must keep.
    private static func strippedBody(ofHTML html: String) -> String {
        let body = HTMLProcessor.firstCapture(of: "<body\\b[^>]*>(.*?)</body\\s*>", in: html)
            ?? HTMLProcessor.firstCapture(of: "<body\\b[^>]*>(.*)", in: html)
            ?? html
        var result = body
        for element in ["header", "nav", "footer", "aside"] {
            // Block with content first, then any stray open/close tag left
            // by unbalanced markup — the sanitize(html:) alternation shape.
            result = HTMLProcessor.replacing(
                pattern: "<\(element)\\b[^>]*>.*?</\(element)\\s*>|</?\(element)\\b[^>]*>",
                in: result,
                with: "")
        }
        return result
    }

    /// Applied to every tier's output: removes <style> blocks, <link> tags,
    /// <noscript> wrappers, and HTML comments; trims surrounding whitespace.
    /// The reading pane's CSP allows 'unsafe-inline' styles, so a page's own
    /// <style> would fight ArticleTemplate's CSS; noscript wrappers duplicate
    /// images; comments can hide tag-shaped text.
    private static func cleanedFragment(_ fragment: String) -> String {
        var result = fragment
        for element in ["style", "noscript"] {
            result = HTMLProcessor.replacing(
                pattern: "<\(element)\\b[^>]*>.*?</\(element)\\s*>|</?\(element)\\b[^>]*>",
                in: result,
                with: "")
        }
        result = HTMLProcessor.replacing(pattern: "<link\\b[^>]*>", in: result, with: "")
        result = HTMLProcessor.replacing(pattern: "<!--.*?-->", in: result, with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasEnoughText(_ fragment: String) -> Bool {
        // The excerpt only fills its budget when the visible text does.
        // (A space straddling the cut can cost one character — irrelevant
        // for a heuristic gate.)
        HTMLProcessor.plainTextExcerpt(from: fragment, maxLength: minimumCandidateTextLength)
            .count >= minimumCandidateTextLength - 1
    }

    private static func collapseWhitespace(_ string: String) -> String {
        string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
