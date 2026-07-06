//
//  FeedAutodiscovery.swift
//  reader
//

import Foundation

/// Finds feeds advertised by an HTML page (<link rel="alternate"
/// type="application/rss+xml" href="…">) so users can paste a blog's
/// homepage URL instead of hunting for its feed.
nonisolated enum FeedAutodiscovery {

    private static let feedTypes: Set<String> = [
        "application/rss+xml",
        "application/atom+xml",
    ]

    /// Advertised feed URLs in document order, deduplicated, resolved
    /// against `baseURL`, http(s) only.
    static func feedURLs(inHTML html: String, baseURL: URL) -> [URL] {
        var seen = Set<URL>()
        var urls: [URL] = []
        for tag in HTMLProcessor.matches(of: "<link\\b[^>]*>", in: html) {
            guard
                let rel = HTMLProcessor.attributeValue("rel", inTag: tag)?.lowercased(),
                rel.split(whereSeparator: \.isWhitespace).contains("alternate"),
                let type = HTMLProcessor.attributeValue("type", inTag: tag)?.lowercased(),
                let essence = type.split(separator: ";").first
                    .map({ $0.trimmingCharacters(in: .whitespaces) }),
                feedTypes.contains(essence),
                let href = HTMLProcessor.attributeValue("href", inTag: tag),
                let url = URL(
                    string: href.trimmingCharacters(in: .whitespacesAndNewlines),
                    relativeTo: baseURL
                )?.absoluteURL,
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { continue }
            if seen.insert(url).inserted {
                urls.append(url)
            }
        }
        return urls
    }
}
