//
//  ReadingPaneView.swift
//  reader
//

import AppKit
import SwiftData
import SwiftUI

/// The article page. All chrome is quiet: the title and byline live inside
/// the web page itself (set like a page, not a web view), and the only
/// native UI is a hover-waking action cluster — or, in focus mode, a 2pt
/// reading-progress bar and the way back out.
struct ReadingPaneView: View {
    @Environment(LinkSaver.self) private var linkSaver
    let article: Article
    @Binding var isFocused: Bool

    @State private var progress: Double = 0
    @State private var hoveringFocusChrome = false

    var body: some View {
        ArticleWebView(
            articleID: article.persistentModelID,
            html: ArticleTemplate.page(contentHTML: article.contentHTML, header: header),
            onSaveLink: { linkSaver.save($0) },
            onProgress: { progress = $0 }
        )
        .overlay(alignment: .top) {
            if isFocused {
                progressBar
            }
        }
        .overlay(alignment: .topTrailing) {
            if isFocused {
                focusChrome
            } else {
                actionCluster
            }
        }
        .background(Theme.page)
    }

    private var header: ArticleTemplate.Header {
        ArticleTemplate.Header(
            title: article.title,
            feedTitle: article.feed?.title,
            author: article.author,
            date: article.sortDate.formatted(.dateTime.day().month(.wide).year())
        )
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Theme.accent)
                .frame(width: proxy.size.width * progress)
        }
        .frame(height: 2)
        .animation(.linear(duration: 0.1), value: progress)
        .allowsHitTesting(false)
    }

    /// Open-in-browser · star · focus. 35% opacity until hovered.
    private var actionCluster: some View {
        HStack(spacing: 2) {
            if let link = article.link {
                QuietIconButton(
                    idleOpacity: 0.35,
                    help: "Open the original article in your browser",
                    action: { NSWorkspace.shared.open(link) }
                ) {
                    Image(systemName: "safari")
                        .font(.system(size: 15))
                }
            }
            QuietIconButton(
                idleOpacity: article.isStarred ? 0.95 : 0.35,
                help: article.isStarred ? "Unstar this article" : "Star this article",
                action: { article.isStarred.toggle() }
            ) {
                Image(systemName: article.isStarred ? "star.fill" : "star")
                    .font(.system(size: 13.5))
                    .foregroundStyle(article.isStarred ? Theme.accent : Theme.inkSoft)
            }
            QuietIconButton(
                idleOpacity: 0.35,
                help: "Focus mode (⌘⏎)",
                action: { isFocused = true }
            ) {
                Image(systemName: "circle.righthalf.filled")
                    .font(.system(size: 14))
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 14)
    }

    /// The way out of focus mode: an esc hint and the ◐ button, nearly
    /// invisible until hovered.
    private var focusChrome: some View {
        HStack(spacing: 8) {
            Text("esc")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.ink.opacity(0.2), lineWidth: 1)
                )
            Button {
                isFocused = false
            } label: {
                Image(systemName: "circle.righthalf.filled")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 26)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Leave focus mode")
        }
        .padding(.top, 12)
        .padding(.trailing, 14)
        .opacity(hoveringFocusChrome ? 1 : 0.35)
        .onHover { hoveringFocusChrome = $0 }
    }
}
