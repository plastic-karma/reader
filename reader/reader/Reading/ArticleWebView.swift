//
//  ArticleWebView.swift
//  reader
//

import SwiftData
import SwiftUI
import WebKit

/// WKWebView wrapper for the reading pane. Loads the templated article HTML
/// and routes link activations out to the user's browser.
struct ArticleWebView: NSViewRepresentable {
    let articleID: PersistentIdentifier
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            LocalAssetSchemeHandler(),
            forURLScheme: LocalAssetSchemeHandler.scheme
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // SwiftUI calls this on unrelated state changes too; reload only
        // when a different article is shown to avoid flicker/scroll loss.
        guard context.coordinator.loadedArticleID != articleID else { return }
        context.coordinator.loadedArticleID = articleID
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedArticleID: PersistentIdentifier?

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
