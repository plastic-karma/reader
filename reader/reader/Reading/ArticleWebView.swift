//
//  ArticleWebView.swift
//  reader
//

import SwiftData
import SwiftUI
import WebKit

/// WKWebView wrapper for the reading pane. Loads the templated article HTML,
/// routes link activations out to the user's browser, and offers "Save Link"
/// in the context menu for links.
struct ArticleWebView: NSViewRepresentable {
    let articleID: PersistentIdentifier
    let html: String
    let onSaveLink: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LinkSavingWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            LocalAssetSchemeHandler(),
            forURLScheme: LocalAssetSchemeHandler.scheme
        )
        let webView = LinkSavingWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.onSaveLink = onSaveLink
        return webView
    }

    func updateNSView(_ webView: LinkSavingWebView, context: Context) {
        // Refresh the closure before the reload guard: updateNSView runs on
        // unrelated state changes where only the closure identity is new.
        webView.onSaveLink = onSaveLink
        // SwiftUI calls this on unrelated state changes too; reload only when
        // a different article is shown — or when the same article's HTML
        // changes under us, which the save-link pipeline does in place
        // (placeholder → snapshot, failure → retry) — to avoid flicker and
        // scroll loss on everything else.
        guard context.coordinator.loadedArticleID != articleID
            || context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedArticleID = articleID
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedArticleID: PersistentIdentifier?
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
