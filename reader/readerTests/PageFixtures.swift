//
//  PageFixtures.swift
//  reader
//

/// Web-page documents for save-link tests, as string literals on purpose:
/// bundle resources would need pbxproj resource-phase edits.
enum PageFixtures {

    /// A filler paragraph comfortably past PageExtractor's 200-character gate.
    static let longParagraph = """
    <p>The quick brown fox jumps over the lazy dog while the observant reader \
    keeps track of every single word in this deliberately long paragraph, which \
    continues well past the two hundred character threshold so that the \
    extraction gate accepts it as genuine article content rather than a teaser \
    card or a comment stub.</p>
    """

    /// og:title + <title>, header/nav chrome, a long first <article> with a
    /// relative image, sibling comment <article>s, and a footer.
    static let articlePage = #"""
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta property="og:title" content="Understanding Swift Actors &amp; Isolation">
    <title>Understanding Swift Actors — Example Blog</title>
    </head>
    <body>
    <header><h1>Example Blog</h1><nav><a href="/">Home</a><a href="/about">About</a></nav></header>
    <article>
    <header><h1>Understanding Swift Actors</h1></header>
    \#(longParagraph)
    <img src="/images/actors-diagram.png" alt="diagram">
    <p>A second paragraph with additional detail about actor isolation.</p>
    </article>
    <section id="comments">
    <article><p>First comment: nice post!</p></article>
    <article><p>Second comment: thanks for writing this.</p></article>
    </section>
    <footer><p>© Example Blog</p></footer>
    </body>
    </html>
    """#

    /// No og:title; the <title> carries entities and ragged whitespace.
    static let titleEntityPage = #"""
    <html>
    <head><title>
        Ben&amp;Jerry&#8217;s   Guide
    </title></head>
    <body>\#(longParagraph)</body>
    </html>
    """#

    /// Every <article> is a short teaser; the real content is in <main>.
    static let teaserThenMainPage = #"""
    <html>
    <head><title>Index — Example</title></head>
    <body>
    <article><p>Teaser one.</p></article>
    <article><p>Teaser two.</p></article>
    <main>
    \#(longParagraph)
    <p>Main content continues here with plenty of additional words.</p>
    </main>
    </body>
    </html>
    """#

    /// No <article>/<main>: body-tier fallback must strip chrome and the
    /// style/link/noscript/comment residue.
    static let bodyChromePage = #"""
    <html>
    <head>
    <title>Legacy Layout</title>
    </head>
    <body>
    <header><h1>Site Header</h1></header>
    <nav><a href="/">Home</a></nav>
    <link rel="stylesheet" href="/styles.css">
    <style>body { background: hotpink; }</style>
    <!-- rendering starts here -->
    \#(longParagraph)
    <noscript><img src="/tracking.gif"></noscript>
    <aside><p>Related posts sidebar</p></aside>
    <footer><p>Legal fine print</p></footer>
    </body>
    </html>
    """#

    /// A served fragment: no <body> at all.
    static let bareFragment = #"""
    <div class="post">\#(longParagraph)</div>
    """#

    /// A <script> body containing a literal "</article>" — proves the
    /// sanitize-before-extract ordering (unsanitized, the block regex would
    /// truncate the article at the fake closing tag).
    static let scriptedArticlePage = #"""
    <html>
    <head><title>Scripted Page</title></head>
    <body>
    <article>
    <script>var template = "<article>fake</article>";</script>
    \#(longParagraph)
    <p>MARKER-AFTER-SCRIPT paragraph proving the article survived whole.</p>
    </article>
    </body>
    </html>
    """#

    /// Two versions of the same URL's page, for re-save tests.
    static let savedPageV1 = #"""
    <html>
    <head><title>Version One</title></head>
    <body><article>\#(longParagraph)<p>V1-MARKER</p></article></body>
    </html>
    """#

    static let savedPageV2 = #"""
    <html>
    <head><title>Version Two</title></head>
    <body><article>\#(longParagraph)<p>V2-MARKER</p></article></body>
    </html>
    """#
}
