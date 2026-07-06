//
//  ReadingPaneView.swift
//  reader
//

import SwiftData
import SwiftUI

/// Article chrome (native SwiftUI header for selection/typography) above the
/// sandboxed web view that renders the cached article body.
struct ReadingPaneView: View {
    @Environment(LinkSaver.self) private var linkSaver
    let article: Article

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            Divider()
            ArticleWebView(
                articleID: article.persistentModelID,
                html: ArticleTemplate.page(contentHTML: article.contentHTML),
                onSaveLink: { linkSaver.save($0) }
            )
        }
        .toolbar {
            ToolbarItem {
                if let link = article.link {
                    Link(destination: link) {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .help("Open the original article in your browser")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title)
                .font(.title2.bold())
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if let feedTitle = article.feed?.title {
                    Text(feedTitle)
                }
                if let author = article.author {
                    Text("·")
                    Text(author)
                }
                Text("·")
                Text(article.sortDate, format: .dateTime.day().month(.wide).year())
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
