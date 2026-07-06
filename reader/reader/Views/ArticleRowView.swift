//
//  ArticleRowView.swift
//  reader
//

import SwiftUI

struct ArticleRowView: View {
    let article: Article

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(.tint)
                .frame(width: 8, height: 8)
                .opacity(article.isRead ? 0 : 1)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.headline)
                    .lineLimit(2)
                if let summary = article.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(article.sortDate, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
