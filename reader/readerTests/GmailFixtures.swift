//
//  GmailFixtures.swift
//  readerTests
//
//  Gmail API JSON as Swift string literals (not bundle resources — same
//  reasoning as Fixtures.swift). Part bodies are genuine base64url of the
//  documented plaintext, so decode tests are byte-accurate; several
//  payloads contain "-"/"_" to exercise the url-safe alphabet.
//

import Foundation

enum GmailFixtures {

    // MARK: - messages.list pages

    static let listPageOne = #"""
    {
      "messages": [
        {"id": "m1", "threadId": "t1"},
        {"id": "m2", "threadId": "t2"}
      ],
      "nextPageToken": "page2",
      "resultSizeEstimate": 3
    }
    """#

    static let listPageTwo = #"""
    {
      "messages": [
        {"id": "m3", "threadId": "t3"}
      ],
      "resultSizeEstimate": 1
    }
    """#

    /// Zero results: Gmail omits `messages` entirely.
    static let listEmpty = #"""
    {"resultSizeEstimate": 0}
    """#

    // MARK: - messages.get format=metadata

    /// In the inbox, unread; RFC 2047 Q-encoded subject ("Café digest") and
    /// B-encoded From display name ("José").
    static let metadataInbox = #"""
    {
      "id": "m1",
      "labelIds": ["UNREAD", "INBOX", "CATEGORY_UPDATES"],
      "internalDate": "1751791234567",
      "payload": {
        "mimeType": "text/html",
        "headers": [
          {"name": "Subject", "value": "=?utf-8?Q?Caf=C3=A9_digest?="},
          {"name": "From", "value": "=?UTF-8?B?Sm9zw6k=?= <news@example.com>"},
          {"name": "Date", "value": "Sun, 06 Jul 2025 08:00:34 +0000"}
        ],
        "body": {"size": 0}
      }
    }
    """#

    /// Already archived (no INBOX label).
    static let metadataArchived = #"""
    {
      "id": "m2",
      "labelIds": ["CATEGORY_UPDATES"],
      "internalDate": "1751791234567",
      "payload": {
        "mimeType": "text/html",
        "headers": [
          {"name": "subject", "value": "Archived one"},
          {"name": "FROM", "value": "news@example.com"}
        ],
        "body": {"size": 0}
      }
    }
    """#

    /// No internalDate — the Date header is the fallback.
    static let metadataDateHeaderOnly = #"""
    {
      "id": "m9",
      "labelIds": ["INBOX"],
      "payload": {
        "mimeType": "text/plain",
        "headers": [
          {"name": "Subject", "value": "Old school"},
          {"name": "From", "value": "n@x.com"},
          {"name": "Date", "value": "Sun, 06 Jul 2025 08:00:34 +0000"}
        ],
        "body": {"size": 0}
      }
    }
    """#

    // MARK: - messages.get format=full

    /// multipart/alternative with plain + html leaves.
    /// html: <h1>Money Stuff</h1><p>Café &amp; markets — onward!</p><img src="https://example.com/hero.png">
    /// plain: "Money Stuff\n\nCafé & markets — onward!\nLine two."
    static let fullMultipartAlternative = #"""
    {
      "id": "full1",
      "labelIds": ["INBOX", "UNREAD"],
      "internalDate": "1751791234567",
      "payload": {
        "mimeType": "multipart/alternative",
        "headers": [
          {"name": "Subject", "value": "=?utf-8?Q?Caf=C3=A9_digest?="},
          {"name": "From", "value": "Matt Levine <money@bloomberg.net>"},
          {"name": "Date", "value": "Sun, 06 Jul 2025 08:00:34 +0000"}
        ],
        "body": {"size": 0},
        "parts": [
          {
            "mimeType": "text/plain",
            "headers": [{"name": "Content-Type", "value": "text/plain; charset=UTF-8"}],
            "body": {"data": "TW9uZXkgU3R1ZmYKCkNhZsOpICYgbWFya2V0cyDigJQgb253YXJkIQpMaW5lIHR3by4=", "size": 58}
          },
          {
            "mimeType": "text/html",
            "headers": [{"name": "Content-Type", "value": "text/html; charset=UTF-8"}],
            "body": {"data": "PGgxPk1vbmV5IFN0dWZmPC9oMT48cD5DYWbDqSAmYW1wOyBtYXJrZXRzIOKAlCBvbndhcmQhPC9wPjxpbWcgc3JjPSJodHRwczovL2V4YW1wbGUuY29tL2hlcm8ucG5nIj4=", "size": 100}
          }
        ]
      }
    }
    """#

    /// multipart/alternative(plain, multipart/related(html, image)) — the
    /// html leaf sits one level down; the image part has no body data.
    /// nested html: <p>Nested <b>rich</b> body</p>
    static let fullNestedRelated = #"""
    {
      "id": "full2",
      "internalDate": "1751791234567",
      "payload": {
        "mimeType": "multipart/alternative",
        "headers": [
          {"name": "Subject", "value": "Nested"},
          {"name": "From", "value": "n@x.com"}
        ],
        "body": {"size": 0},
        "parts": [
          {
            "mimeType": "text/plain",
            "body": {"data": "SGVsbG8gcGxhaW4gd29ybGQuCgpTZWNvbmQgcGFyYWdyYXBoICYgPG1vcmU-Lg==", "size": 44}
          },
          {
            "mimeType": "multipart/related",
            "body": {"size": 0},
            "parts": [
              {
                "mimeType": "text/html",
                "headers": [{"name": "Content-Type", "value": "text/html; charset=utf-8"}],
                "body": {"data": "PHA-TmVzdGVkIDxiPnJpY2g8L2I-IGJvZHk8L3A-", "size": 28}
              },
              {
                "mimeType": "image/png",
                "body": {"attachmentId": "att1", "size": 4096}
              }
            ]
          }
        ]
      }
    }
    """#

    /// Single-part text/plain, no Subject header.
    /// plain: "Hello plain world.\n\nSecond paragraph & <more>."
    static let fullPlainOnly = #"""
    {
      "id": "full3",
      "internalDate": "1751791234567",
      "payload": {
        "mimeType": "text/plain",
        "headers": [
          {"name": "From", "value": "plain@x.com"},
          {"name": "Content-Type", "value": "text/plain; charset=UTF-8"}
        ],
        "body": {"data": "SGVsbG8gcGxhaW4gd29ybGQuCgpTZWNvbmQgcGFyYWdyYXBoICYgPG1vcmU-Lg==", "size": 47}
      }
    }
    """#

    /// Single-part html in ISO-8859-1 (0xE9 é byte) with a quoted charset.
    /// html: <p>héllo latin</p>
    static let fullLatin1 = #"""
    {
      "id": "full4",
      "internalDate": "1751791234567",
      "payload": {
        "mimeType": "text/html",
        "headers": [
          {"name": "Subject", "value": "Latin"},
          {"name": "From", "value": "l@x.com"},
          {"name": "Content-Type", "value": "text/html; charset=\"ISO-8859-1\""}
        ],
        "body": {"data": "PHA-aOlsbG8gbGF0aW48L3A-", "size": 18}
      }
    }
    """#
}
