//
//  LocalAssetSchemeHandler.swift
//  reader
//

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves reader-asset://<sha256>.<ext> from the on-disk ImageCache, plus
/// reader-asset://fonts/<name> for the bundled reading face. The custom
/// scheme keeps persisted article HTML location-independent and composes
/// with the CSP (img-src/font-src reader-asset:) for offline-only rendering.
@MainActor
final class LocalAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    nonisolated static let scheme = "reader-asset"

    /// Content-addressed names only — anything else (paths, traversal
    /// attempts, odd characters) is rejected outright.
    private static let nameFormat = /^[a-f0-9]{64}\.[a-z0-9]{1,8}$/

    /// Fixed allowlist under the "fonts" host — requests never name bundle
    /// resources directly.
    private static let bundledFonts: [String: String] = [
        "/literata.ttf": "Literata",
        "/literata-italic.ttf": "Literata-Italic",
    ]

    /// Tasks WebKit hasn't stopped. Delivery happens after an off-main file
    /// read, and messaging a task after stop() is a WebKit exception.
    private var liveTasks = Set<ObjectIdentifier>()

    private nonisolated static func fileURL(for url: URL) -> URL? {
        guard let host = url.host() else { return nil }
        if host == "fonts" {
            guard let resource = bundledFonts[url.path()] else { return nil }
            return Bundle.main.url(forResource: resource, withExtension: "ttf")
                ?? Bundle.main.url(forResource: resource, withExtension: "ttf", subdirectory: "Fonts")
        }
        guard host.wholeMatch(of: nameFormat) != nil else { return nil }
        return ImageCache.directoryURL.appending(path: host)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard
            let url = urlSchemeTask.request.url,
            let file = Self.fileURL(for: url)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let identity = ObjectIdentifier(urlSchemeTask)
        liveTasks.insert(identity)
        Task {
            // Off the main actor: image-heavy articles would otherwise block
            // the UI with one synchronous disk read per <img>.
            let data = await Task.detached {
                try? Data(contentsOf: file)
            }.value
            guard liveTasks.remove(identity) != nil else { return }
            guard let data else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            urlSchemeTask.didReceive(URLResponse(
                url: url,
                mimeType: mime,
                expectedContentLength: data.count,
                textEncodingName: nil
            ))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(urlSchemeTask))
    }
}
