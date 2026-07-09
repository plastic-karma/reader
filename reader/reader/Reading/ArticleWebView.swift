//
//  ArticleWebView.swift
//  reader
//

import SwiftData
import SwiftUI
import WebKit

/// WKWebView wrapper for the reading pane. Loads the templated article HTML,
/// routes link activations out to the user's browser, offers "Save Link" in
/// the context menu for links, and reports reading progress (0…1) from the
/// page's scroll position for the focus-mode progress bar.
struct ArticleWebView: NSViewRepresentable {
    let articleID: PersistentIdentifier
    let html: String
    let onSaveLink: (URL) -> Void
    var onProgress: ((Double) -> Void)? = nil

    /// Injected via WKUserContentController, so it runs despite the page
    /// CSP having no script-src (user scripts are exempt by design — the
    /// document itself still can't execute anything).
    private static let progressScript = """
        (function () {
          let ticking = false;
          const report = function () {
            ticking = false;
            const max = document.documentElement.scrollHeight - window.innerHeight;
            const p = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
            window.webkit.messageHandlers.readerScroll.postMessage(p);
          };
          const schedule = function () {
            if (!ticking) { ticking = true; requestAnimationFrame(report); }
          };
          window.addEventListener('scroll', schedule, { passive: true });
          window.addEventListener('resize', schedule, { passive: true });
          report();
        })();
        """

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LinkSavingWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            LocalAssetSchemeHandler(),
            forURLScheme: LocalAssetSchemeHandler.scheme
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.progressScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.add(context.coordinator, name: "readerScroll")
        let webView = LinkSavingWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.onSaveLink = onSaveLink
        // Match the paper so load and overscroll never flash white.
        webView.underPageBackgroundColor = NSColor(Theme.page)
        return webView
    }

    static func dismantleNSView(_ webView: LinkSavingWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "readerScroll")
    }

    func updateNSView(_ webView: LinkSavingWebView, context: Context) {
        // Refresh the closures before the reload guard: updateNSView runs on
        // unrelated state changes where only the closure identity is new.
        webView.onSaveLink = onSaveLink
        context.coordinator.onProgress = onProgress
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedArticleID: PersistentIdentifier?
        var loadedHTML: String?
        var onProgress: ((Double) -> Void)?

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

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "readerScroll",
                  let value = message.body as? Double else { return }
            onProgress?(min(max(value, 0), 1))
        }
    }
}
