//
//  Fixtures.swift
//  reader
//

/// Feed documents for parser tests, as string literals on purpose:
/// bundle resources would need pbxproj resource-phase edits.
enum Fixtures {

    /// RSS 2.0: guids, pubDates, dc:creator, CDATA description, an HTML
    /// entity in a title, content:encoded on the first item only.
    static let rss2Basic = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:content="http://purl.org/rss/1.0/modules/content/">
      <channel>
        <title>Example Blog</title>
        <link>https://example.com/</link>
        <description>Notes on things.</description>
        <item>
          <title>Apple&amp;#8217;s Quiet Update</title>
          <link>https://example.com/posts/quiet-update</link>
          <guid isPermaLink="false">post-1001</guid>
          <pubDate>Mon, 02 Jun 2025 09:30:00 GMT</pubDate>
          <dc:creator>Jane Doe</dc:creator>
          <description><![CDATA[<p>A short &amp; sweet summary.</p>]]></description>
          <content:encoded><![CDATA[<p>The <em>full</em> story, with details.</p>]]></content:encoded>
        </item>
        <item>
          <title>Second Post</title>
          <link>https://example.com/posts/second</link>
          <guid isPermaLink="false">post-1002</guid>
          <pubDate>Tue, 03 Jun 2025 18:05:12 +0200</pubDate>
          <dc:creator>John Smith</dc:creator>
          <description>Plain description only.</description>
        </item>
      </channel>
    </rss>
    """#

    /// Items carry links but no guids — stableID must fall back to the link.
    static let rssNoGuids = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Linkline</title>
        <link>https://linkline.example.net/</link>
        <item>
          <title>First Link</title>
          <link>https://linkline.example.net/posts/first</link>
          <description>First body.</description>
        </item>
        <item>
          <title>Second Link</title>
          <link>https://linkline.example.net/posts/second</link>
          <description>Second body.</description>
        </item>
      </channel>
    </rss>
    """#

    /// Items with neither guid nor link — stableID must fall back to a hash.
    static let rssBareItems = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Bare Notes</title>
        <item>
          <title>Note One</title>
          <pubDate>Wed, 04 Jun 2025 07:00:00 GMT</pubDate>
          <description>Body one.</description>
        </item>
        <item>
          <title>Note Two</title>
          <pubDate>Thu, 05 Jun 2025 07:00:00 GMT</pubDate>
          <description>Body two.</description>
        </item>
      </channel>
    </rss>
    """#

    /// Atom: rel=self and rel=alternate at feed and entry level, a rel-less
    /// entry link, content on the first entry only, updated-only second entry.
    static let atomBasic = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Atom Journal</title>
      <link rel="self" href="https://atom.example.org/feed.xml"/>
      <link rel="alternate" href="https://atom.example.org/"/>
      <updated>2025-06-05T12:00:00Z</updated>
      <id>urn:uuid:feed-root</id>
      <author>
        <name>Site Author</name>
      </author>
      <entry>
        <title>Entry One</title>
        <id>urn:uuid:entry-1</id>
        <link rel="self" href="https://atom.example.org/api/entries/1"/>
        <link rel="alternate" href="https://atom.example.org/entries/one"/>
        <published>2025-06-04T08:15:30Z</published>
        <updated>2025-06-04T09:00:00Z</updated>
        <author>
          <name>Ada Lovelace</name>
        </author>
        <summary>A short abstract.</summary>
        <content type="html">&lt;p&gt;Full &lt;strong&gt;content&lt;/strong&gt; here.&lt;/p&gt;</content>
      </entry>
      <entry>
        <title>Entry Two</title>
        <id>urn:uuid:entry-2</id>
        <link href="https://atom.example.org/entries/two"/>
        <updated>2025-06-05T10:00:00Z</updated>
        <summary>Only a summary.</summary>
      </entry>
    </feed>
    """#

    /// Atom entry whose content is inline XHTML (child elements, not escaped
    /// markup) — the parser must reconstruct markup from the XML events.
    static let atomXHTMLContent = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>XHTML Journal</title>
      <link rel="alternate" href="https://xhtml.example.org/"/>
      <updated>2025-06-06T12:00:00Z</updated>
      <id>urn:uuid:feed-xhtml</id>
      <entry>
        <title>Inline Markup</title>
        <id>urn:uuid:entry-xhtml-1</id>
        <link rel="alternate" href="https://xhtml.example.org/entries/one"/>
        <published>2025-06-06T08:00:00Z</published>
        <summary>Plain summary.</summary>
        <content type="xhtml">
          <div xmlns="http://www.w3.org/1999/xhtml">Hello <b>world</b> &amp; more<br/>done</div>
        </content>
      </entry>
    </feed>
    """#

    static let notAFeedHTML = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="utf-8">
        <title>Just a Page</title>
    </head>
    <body>
        <p>This is not a feed.</p>
    </body>
    </html>
    """#

    /// Mismatched closing tag and truncated document.
    static let malformedXML = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Broken Feed</title>
        <item>
          <title>Broken item</titel>
        </item>
    """#
}
