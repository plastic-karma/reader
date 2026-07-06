//
//  FeedParser.swift
//  reader
//

import CryptoKit
import Foundation

nonisolated struct ParsedFeed: Sendable {
    let title: String?
    let homepageURL: URL?
    let items: [ParsedItem]
}

nonisolated struct ParsedItem: Sendable {
    let stableID: String
    let title: String
    let author: String?
    let link: URL?
    let publishedAt: Date?
    let summaryHTML: String?
    let contentHTML: String
}

nonisolated enum FeedParseError: Error {
    case notAFeed
    case malformed(String)
}

/// Parses RSS 2.0 / RSS 1.0 (RDF) and Atom documents into plain value types.
nonisolated enum FeedParser {

    static func parse(data: Data, sourceURL: URL) throws -> ParsedFeed {
        let delegate = FeedXMLDelegate(sourceURL: sourceURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        let finished = parser.parse()

        if let earlyError = delegate.earlyError {
            throw earlyError
        }
        guard finished, delegate.parseFailure == nil else {
            let description = delegate.parseFailure
                ?? parser.parserError?.localizedDescription
                ?? "unreadable XML"
            throw FeedParseError.malformed(description)
        }
        guard delegate.format != nil else {
            throw FeedParseError.notAFeed
        }
        return ParsedFeed(
            title: delegate.feedTitle,
            homepageURL: delegate.homepageURL,
            items: delegate.items
        )
    }
}

/// XMLParser state machine shared by both formats. Tracks the open-element
/// path so that, e.g., an <item> title never overwrites the channel title
/// and elements nested inside unknown containers are ignored.
private nonisolated final class FeedXMLDelegate: NSObject, XMLParserDelegate {

    enum Format {
        case rss
        case atom
    }

    private(set) var format: Format?
    private(set) var earlyError: FeedParseError?
    private(set) var parseFailure: String?
    private(set) var feedTitle: String?
    private(set) var homepageURL: URL?
    private(set) var items: [ParsedItem] = []

    private let sourceURL: URL
    /// Qualified names of the currently open elements, root first.
    private var path: [String] = []
    /// Character/CDATA accumulator for the innermost open element.
    private var text = ""

    private struct PendingItem {
        var depth: Int
        var title = ""
        var guid = ""
        var link = ""
        var author = ""
        var dateRaw = ""       // RSS pubDate / Atom published
        var updatedRaw = ""    // Atom updated (date fallback)
        var summary: String?   // RSS description / Atom summary
        var content: String?   // RSS content:encoded / Atom content
    }

    private var item: PendingItem?
    /// Depth of an Atom content/summary element with type="xhtml". While set,
    /// nested elements are serialized back into `text` as markup instead of
    /// resetting the accumulator (inline XHTML arrives as XML events, not as
    /// escaped text like type="html" does).
    private var xhtmlCaptureDepth: Int?

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if path.isEmpty {
            switch elementName {
            case "rss", "rdf:RDF":
                format = .rss
            case "feed":
                format = .atom
            default:
                earlyError = .notAFeed
                parser.abortParsing()
                return
            }
        }

        if let captureDepth = xhtmlCaptureDepth, path.count >= captureDepth {
            path.append(elementName)
            text += serializedStartTag(elementName, attributes: attributeDict)
            return
        }

        path.append(elementName)
        text = ""

        switch format {
        case .rss:
            if elementName == "item", item == nil {
                item = PendingItem(depth: path.count)
            }
        case .atom:
            if elementName == "entry", item == nil {
                item = PendingItem(depth: path.count)
            } else if elementName == "link" {
                handleAtomLink(attributes: attributeDict)
            } else if let pending = item,
                      path.count == pending.depth + 1,
                      elementName == "content" || elementName == "summary",
                      attributeDict["type"] == "xhtml" {
                xhtmlCaptureDepth = path.count
            }
        case nil:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if xhtmlCaptureDepth != nil {
            text += escapedXMLText(string)
        } else {
            text += string
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // Ignore the error our own abortParsing() raises for .notAFeed.
        if earlyError == nil, parseFailure == nil {
            parseFailure = parseError.localizedDescription
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let block = String(data: CDATABlock, encoding: .utf8)
            ?? String(data: CDATABlock, encoding: .isoLatin1) {
            text += xhtmlCaptureDepth != nil ? escapedXMLText(block) : block
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if let captureDepth = xhtmlCaptureDepth {
            if path.count > captureDepth {
                if !Self.voidElements.contains(elementName.lowercased()) {
                    text += "</\(elementName)>"
                }
                path.removeLast()
                return
            }
            // Closing the captured content/summary element itself: fall
            // through so the accumulated markup is assigned normally.
            xhtmlCaptureDepth = nil
        }
        switch format {
        case .rss:
            endRSSElement(elementName)
        case .atom:
            endAtomElement(elementName)
        case nil:
            break
        }
        if !path.isEmpty {
            path.removeLast()
        }
        text = ""
    }

    // MARK: - RSS

    private func endRSSElement(_ elementName: String) {
        if var pending = item {
            if elementName == "item", path.count == pending.depth {
                item = nil
                finishItem(pending)
            } else if path.count == pending.depth + 1 {
                switch elementName {
                case "title":
                    pending.title = text
                case "link":
                    pending.link = text
                case "guid":
                    pending.guid = trimmed(text)
                case "pubDate":
                    pending.dateRaw = trimmed(text)
                case "dc:creator":
                    pending.author = text
                case "description":
                    pending.summary = text
                case "content:encoded":
                    pending.content = text
                default:
                    return
                }
                item = pending
            }
            return
        }
        guard path.count >= 2, path[path.count - 2] == "channel" else { return }
        switch elementName {
        case "title":
            let title = cleanedText(text)
            feedTitle = title.isEmpty ? nil : title
        case "link":
            homepageURL = resolvedURL(trimmed(text))
        default:
            break
        }
    }

    // MARK: - Atom

    private func endAtomElement(_ elementName: String) {
        if var pending = item {
            if elementName == "entry", path.count == pending.depth {
                item = nil
                finishItem(pending)
            } else if path.count == pending.depth + 1 {
                switch elementName {
                case "title":
                    pending.title = text
                case "id":
                    pending.guid = trimmed(text)
                case "published":
                    pending.dateRaw = trimmed(text)
                case "updated":
                    pending.updatedRaw = trimmed(text)
                case "summary":
                    pending.summary = text
                case "content":
                    pending.content = text
                default:
                    return
                }
                item = pending
            } else if elementName == "name",
                      path.count == pending.depth + 2,
                      path[path.count - 2] == "author" {
                pending.author = text
                item = pending
            }
            return
        }
        guard path.count == 2, elementName == "title" else { return }
        let title = cleanedText(text)
        feedTitle = title.isEmpty ? nil : title
    }

    /// Atom <link> is attribute-based, so it is handled at element start.
    /// Accepts rel="alternate" or no rel at all (the Atom default); anything
    /// else (self, hub, enclosure, ...) is ignored. First acceptable link wins.
    private func handleAtomLink(attributes: [String: String]) {
        let rel = attributes["rel"]
        guard rel == nil || rel == "alternate",
              let href = attributes["href"] else { return }
        if var pending = item {
            guard path.count == pending.depth + 1, pending.link.isEmpty else { return }
            pending.link = href
            item = pending
        } else if path.count == 2, homepageURL == nil {
            homepageURL = resolvedURL(trimmed(href))
        }
    }

    // MARK: - Item assembly

    private func finishItem(_ pending: PendingItem) {
        let title = cleanedText(pending.title)
        let author = cleanedText(pending.author)
        let linkString = trimmed(pending.link)
        let content = trimmed(pending.content ?? "")
        let summary = pending.summary.map(trimmed)
        let contentHTML = content.isEmpty ? (summary ?? "") : content

        // Defensive: a garbage entry with nothing to identify it and nothing to show.
        if pending.guid.isEmpty, linkString.isEmpty, title.isEmpty, contentHTML.isEmpty {
            return
        }

        let dateRaw = pending.dateRaw.isEmpty ? pending.updatedRaw : pending.dateRaw

        let stableID: String
        if !pending.guid.isEmpty {
            stableID = pending.guid
        } else if !linkString.isEmpty {
            stableID = linkString
        } else {
            stableID = Self.sha256Hex(title + "|" + dateRaw)
        }

        items.append(ParsedItem(
            stableID: stableID,
            title: title.isEmpty ? "(untitled)" : title,
            author: author.isEmpty ? nil : author,
            link: resolvedURL(linkString),
            publishedAt: dateRaw.isEmpty ? nil : FeedDates.parse(dateRaw),
            summaryHTML: summary.flatMap { $0.isEmpty ? nil : $0 },
            contentHTML: contentHTML
        ))
    }

    // MARK: - XHTML reconstruction

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "source", "track", "wbr",
    ]

    /// Attributes sorted by name so reconstructed markup is deterministic.
    private func serializedStartTag(_ name: String, attributes: [String: String]) -> String {
        var tag = "<" + name
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            tag += " \(key)=\"\(escapedXMLText(value).replacingOccurrences(of: "\"", with: "&quot;"))\""
        }
        return tag + (Self.voidElements.contains(name.lowercased()) ? "/>" : ">")
    }

    /// XMLParser hands text back decoded; re-escape it when rebuilding markup.
    private func escapedXMLText(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    // MARK: - Helpers

    private func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanedText(_ string: String) -> String {
        trimmed(HTMLProcessor.decodeHTMLEntities(string))
    }

    private func resolvedURL(_ string: String) -> URL? {
        guard !string.isEmpty else { return nil }
        return URL(string: string, relativeTo: sourceURL)?.absoluteURL
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
