//
//  ArticleTemplate.swift
//  reader
//

import Foundation

/// Wraps sanitized article HTML in a full document with a strict CSP —
/// nothing loads except inline styles and locally cached reader-asset:
/// images, so rendering is offline-verified by construction.
nonisolated enum ArticleTemplate {

    static let contentSecurityPolicy =
        "default-src 'none'; img-src reader-asset:; style-src 'unsafe-inline'"

    static func page(contentHTML: String) -> String {
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
        \(contentHTML)
        </article></body>
        </html>
        """
    }

    /// System colors + color-scheme give automatic light/dark rendering.
    private static let readingCSS = """
        :root {
            color-scheme: light dark;
        }
        body {
            font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            color: CanvasText;
            background: Canvas;
            margin: 0;
            padding: 24px 32px 48px;
        }
        article {
            max-width: 42em;
            margin: 0 auto;
        }
        h1, h2, h3, h4 {
            line-height: 1.25;
        }
        a {
            color: LinkText;
        }
        img, video, figure {
            max-width: 100%;
            height: auto;
        }
        figure {
            margin: 1em 0;
        }
        figcaption {
            font-size: 0.85em;
            opacity: 0.7;
        }
        pre, code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.9em;
        }
        pre {
            overflow-x: auto;
            padding: 12px;
            border-radius: 6px;
            background: color-mix(in srgb, CanvasText 7%, Canvas);
        }
        blockquote {
            margin: 1em 0;
            padding-left: 1em;
            border-left: 3px solid color-mix(in srgb, CanvasText 25%, Canvas);
            opacity: 0.85;
        }
        hr {
            border: none;
            border-top: 1px solid color-mix(in srgb, CanvasText 15%, Canvas);
            margin: 2em 0;
        }
        table {
            border-collapse: collapse;
            display: block;
            overflow-x: auto;
        }
        td, th {
            border: 1px solid color-mix(in srgb, CanvasText 20%, Canvas);
            padding: 6px 10px;
        }
        """
}
