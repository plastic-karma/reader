//
//  ArticleTemplate.swift
//  reader
//

import Foundation

/// Wraps sanitized article HTML in a full document with a strict CSP —
/// nothing loads except inline styles, locally cached reader-asset: images,
/// and the bundled reading face, so rendering is offline-verified by
/// construction.
///
/// The page owns the article chrome too: title and byline render inside the
/// document (set like a page, not a web view), sharing one ink + accent
/// scheme with the body. Values mirror `Theme`.
nonisolated enum ArticleTemplate {

    static let contentSecurityPolicy =
        "default-src 'none'; img-src reader-asset:; font-src reader-asset:; style-src 'unsafe-inline'"

    /// In-page article header. Strings are display-ready; escaping happens
    /// here.
    struct Header {
        var title: String
        var feedTitle: String?
        var author: String?
        var date: String?
    }

    static func page(contentHTML: String, header: Header? = nil) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(readingCSS)
        </style>
        </head>
        <body><article>
        \(header.map(headerHTML) ?? "")<div class="reader-content">
        \(contentHTML)
        </div>
        </article></body>
        </html>
        """
    }

    private static func headerHTML(_ header: Header) -> String {
        var spans: [String] = []
        if let feed = header.feedTitle, !feed.isEmpty {
            spans.append("<span class=\"reader-feed\">\(escaped(feed))</span>")
        }
        if let author = header.author, !author.isEmpty {
            spans.append("<span class=\"reader-meta\">\(escaped(author))</span>")
        }
        if let date = header.date, !date.isEmpty {
            spans.append("<span class=\"reader-meta\">\(escaped(date))</span>")
        }
        let byline = spans.isEmpty
            ? ""
            : "\n<div class=\"reader-byline\">\(spans.joined(separator: "<span class=\"reader-sep\">·</span>"))</div>"
        return """
        <header class="reader-head">
        <h1 class="reader-title">\(escaped(header.title))</h1>\(byline)
        </header>

        """
    }

    /// Minimal HTML entity escaping for text interpolated into the page.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Warm-paper reading page: Literata (bundled, served over the local
    /// scheme) at 19px/1.72 on a 620px measure, one rust accent for links,
    /// quotes and emphasis. Deliberately light-only — the paper is the
    /// identity.
    private static let readingCSS = """
        @font-face {
            font-family: "Literata";
            src: url("reader-asset://fonts/literata.ttf") format("truetype-variations");
            font-weight: 200 900;
            font-style: normal;
        }
        @font-face {
            font-family: "Literata";
            src: url("reader-asset://fonts/literata-italic.ttf") format("truetype-variations");
            font-weight: 200 900;
            font-style: italic;
        }
        :root {
            color-scheme: light;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            color: #241B10;
            background: #FBF9F4;
            margin: 0;
            padding: 56px 48px 110px;
            -webkit-font-smoothing: antialiased;
        }
        ::selection {
            background: rgba(166, 75, 36, 0.18);
        }
        article {
            max-width: 620px;
            margin: 0 auto;
        }
        .reader-title {
            font-family: Literata, Georgia, serif;
            font-size: 34px;
            line-height: 1.18;
            font-weight: 600;
            letter-spacing: -0.01em;
            margin: 0;
            text-wrap: pretty;
        }
        .reader-byline {
            display: flex;
            align-items: baseline;
            flex-wrap: wrap;
            gap: 9px;
            margin-top: 16px;
        }
        .reader-byline span {
            font-size: 11px;
            letter-spacing: 0.1em;
            text-transform: uppercase;
        }
        .reader-feed {
            font-weight: 650;
            letter-spacing: 0.13em;
            color: #A64B24;
        }
        .reader-meta {
            font-weight: 500;
            color: rgba(36, 27, 16, 0.5);
        }
        .reader-sep {
            color: rgba(36, 27, 16, 0.35);
        }
        .reader-content {
            font-family: Literata, Georgia, serif;
            font-size: 19px;
            line-height: 1.72;
        }
        .reader-head + .reader-content {
            margin-top: 36px;
        }
        h1, h2, h3, h4 {
            line-height: 1.3;
            font-weight: 600;
            letter-spacing: -0.005em;
            margin: 1.5em 0 0.6em;
        }
        h1 { font-size: 26px; }
        h2 { font-size: 23px; }
        h3 { font-size: 21px; }
        h4 { font-size: 19px; }
        p {
            margin: 0 0 1.15em;
        }
        a {
            color: #A64B24;
            text-decoration-thickness: 1px;
            text-underline-offset: 3px;
        }
        a:hover {
            color: #8C3D1B;
        }
        img, video, figure {
            max-width: 100%;
            height: auto;
        }
        figure {
            margin: 1.6em 0;
        }
        figcaption {
            font-size: 14px;
            line-height: 1.5;
            color: rgba(36, 27, 16, 0.55);
            margin-top: 8px;
        }
        pre, code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
        }
        pre {
            overflow-x: auto;
            padding: 14px 16px;
            border-radius: 8px;
            background: #F1EBDE;
            font-size: 13.5px;
            line-height: 1.55;
            color: #43382A;
            margin: 0 0 1.3em;
        }
        code {
            font-size: 15px;
            background: rgba(60, 40, 10, 0.07);
            padding: 1px 5px;
            border-radius: 4px;
        }
        pre code {
            font-size: inherit;
            background: none;
            padding: 0;
            border-radius: 0;
        }
        ul, ol {
            margin: 0 0 1.15em;
            padding-left: 1.35em;
        }
        li {
            margin: 0 0 0.35em;
        }
        blockquote {
            margin: 1.4em 0;
            padding: 2px 0 2px 20px;
            border-left: 2px solid rgba(166, 75, 36, 0.55);
            font-style: italic;
            color: rgba(36, 27, 16, 0.75);
        }
        blockquote p:last-child {
            margin-bottom: 0;
        }
        hr {
            border: none;
            border-top: 1px solid rgba(50, 35, 15, 0.15);
            margin: 2em 0;
        }
        table {
            border-collapse: collapse;
            display: block;
            overflow-x: auto;
            font-size: 16px;
        }
        td, th {
            border: 1px solid rgba(50, 35, 15, 0.18);
            padding: 6px 10px;
        }
        """
}
