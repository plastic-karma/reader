//
//  LocalAssetSchemeHandler.swift
//  reader
//

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves reader-asset://<sha256>.<ext> from the on-disk ImageCache. The
/// custom scheme keeps persisted article HTML location-independent and
/// composes with the CSP (img-src reader-asset:) for offline-only rendering.
@MainActor
final class LocalAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    nonisolated static let scheme = "reader-asset"

    /// Content-addressed names only — anything else (paths, traversal
    /// attempts, odd characters) is rejected outright.
    private static let nameFormat = /^[a-f0-9]{64}\.[a-z0-9]{1,8}$/

    /// Tasks WebKit hasn't stopped. Delivery happens after an off-main file
    /// read, and messaging a task after stop() is a WebKit exception.
    private var liveTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard
            let url = urlSchemeTask.request.url,
            let name = url.host(),
            name.wholeMatch(of: Self.nameFormat) != nil
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let identity = ObjectIdentifier(urlSchemeTask)
        liveTasks.insert(identity)
        let file = ImageCache.directoryURL.appending(path: name)
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
            let ext = (name as NSString).pathExtension
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
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
