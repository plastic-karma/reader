//
//  LinkSavingWebView.swift
//  reader
//

import AppKit
import WebKit

/// WKWebView that appends a "Save Link" item to the context menu WebKit
/// builds for links, resolving the clicked anchor's URL only when the item
/// is actually chosen (via elementFromPoint) — no injected user script, and
/// no race against the menu opening.
final class LinkSavingWebView: WKWebView {

    /// Invoked with the absolute http(s) URL of the right-clicked link.
    /// Must not capture this web view (the view retains it strongly).
    var onSaveLink: ((URL) -> Void)?

    /// View-space location of the right-click that opened the current menu.
    /// Deliberately NOT cleared on menu close: AppKit fires menu-close
    /// callbacks before the selected item's action, so clearing there would
    /// break the action. Overwritten on the next willOpenMenu.
    private var lastMenuEventViewPoint: CGPoint?

    private static let saveLinkItemIdentifier =
        NSUserInterfaceItemIdentifier("reader.saveLink")

    /// WebKit's private-but-stable identifiers that mark a link context
    /// menu. Matched by rawValue string through public NSMenu API only.
    private static let linkItemIdentifiers: Set<String> = [
        "WKMenuItemIdentifierOpenLink",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierCopyLink",
        "WKMenuItemIdentifierDownloadLinkedFile",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // "Open Link in New Window" is a silent no-op without a WKUIDelegate.
        if let index = menu.items.firstIndex(where: {
            $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
        }) {
            menu.removeItem(at: index)
        }
        guard !menu.items.contains(where: { $0.identifier == Self.saveLinkItemIdentifier }) else {
            return
        }
        let linkIndexes = menu.items.indices.filter { index in
            guard let id = menu.items[index].identifier else { return false }
            return Self.linkItemIdentifiers.contains(id.rawValue)
        }
        guard let lastLinkIndex = linkIndexes.max() else { return }  // not a link menu
        lastMenuEventViewPoint = convert(event.locationInWindow, from: nil)
        let item = NSMenuItem(
            title: "Save Link",
            action: #selector(saveLinkSelected(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.identifier = Self.saveLinkItemIdentifier
        menu.insertItem(.separator(), at: lastLinkIndex + 1)
        menu.insertItem(item, at: lastLinkIndex + 2)
    }

    @objc private func saveLinkSelected(_ sender: NSMenuItem) {
        guard let viewPoint = lastMenuEventViewPoint else { return }
        resolveLinkURL(atViewPoint: viewPoint) { [weak self] url in
            guard let self, let url else { return }  // null resolution → no-op
            self.onSaveLink?(url)
        }
    }

    private func resolveLinkURL(
        atViewPoint viewPoint: CGPoint,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        let css = cssPoint(forViewPoint: viewPoint)
        // elementFromPoint returns the deepest element (an img/span inside
        // the anchor); closest() walks up. The href *property* is the
        // resolved URL — with baseURL nil, relative hrefs resolve into
        // non-http garbage that the scheme guard below rejects. The typeof
        // branch handles SVG <a>, whose href is an SVGAnimatedString.
        let js = """
        (function () {
            const el = document.elementFromPoint(\(css.x), \(css.y));
            const anchor = el ? el.closest("a[href]") : null;
            if (!anchor) { return null; }
            return typeof anchor.href === "string" ? anchor.href : anchor.href.baseVal;
        })();
        """
        evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
            guard
                case .success(let value) = result,
                let string = value as? String,
                let url = URL(string: string),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    /// AppKit view point → CSS viewport point for elementFromPoint.
    private func cssPoint(forViewPoint point: CGPoint) -> CGPoint {
        // WKWebView is flipped (top-left origin) on modern macOS, but that
        // is a per-class detail — honor the runtime value, don't assume.
        let topLeftY = isFlipped ? point.y : bounds.height - point.y
        // Pinch magnification (allowsMagnification is on) and pageZoom both
        // scale CSS pixels relative to view points.
        let scale = magnification * pageZoom
        guard scale > 0 else { return CGPoint(x: point.x, y: topLeftY) }
        return CGPoint(x: point.x / scale, y: topLeftY / scale)
    }
}
