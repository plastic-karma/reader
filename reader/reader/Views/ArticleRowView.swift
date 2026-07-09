//
//  ArticleRowView.swift
//  reader
//

import SwiftUI

/// One list row. Unread is a weight, not a badge: unread titles carry the
/// ink at semibold with a 5pt rust tick; read rows recede to half ink.
/// Selection is a soft rust wash with a 2pt leading bar — nothing that
/// fights the article for attention.
struct ArticleRowView: View {
    let article: Article
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 5, height: 5)
                    .padding(.top, 6)
                    .opacity(article.isRead ? 0 : 1)
                Text(article.title)
                    .font(.system(size: 13, weight: article.isRead ? .regular : .semibold))
                    .foregroundStyle(article.isRead && !isSelected ? Theme.ink.opacity(0.5) : Theme.ink)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(article.sortDate.compactAge())
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.38))
                    .padding(.top, 2)
            }
            if let summary = article.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .lineLimit(1)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.accent.opacity(0.09) : .clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.accent).frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
