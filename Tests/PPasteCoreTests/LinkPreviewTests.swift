import Testing
import Foundation
@testable import PPasteCore

@Suite struct LinkMetadataParserTests {
    let base = URL(string: "https://example.com/blog/post?x=1")!

    @Test func parsesOpenGraph() {
        let html = """
        <html><head><title>Fallback</title>
        <meta property="og:title" content="OG Title">
        <meta property="og:image" content="https://cdn.example.com/a.png">
        <link rel="icon" href="/fav.png"></head><body></body></html>
        """
        let m = LinkMetadataParser.parse(html: html, baseURL: base)
        #expect(m.title == "OG Title")
        #expect(m.imageURL?.absoluteString == "https://cdn.example.com/a.png")
        #expect(m.iconURL?.absoluteString == "https://example.com/fav.png")
    }

    @Test func resolvesRelativeAndProtocolRelativeURLs() {
        let html = """
        <meta property="og:image" content="../img/cover.jpg">
        <link rel="shortcut icon" href="//static.example.com/i.ico">
        """
        let m = LinkMetadataParser.parse(html: html, baseURL: base)
        #expect(m.imageURL?.absoluteString == "https://example.com/img/cover.jpg")
        #expect(m.iconURL?.absoluteString == "https://static.example.com/i.ico")
    }

    @Test func fallsBackToTitleTagAndHandlesMissingTags() {
        let m = LinkMetadataParser.parse(html: "<head><TITLE>\n  Hello \n World </TITLE></head>", baseURL: base)
        #expect(m.title == "Hello World")
        #expect(m.imageURL == nil)
        #expect(m.iconURL == nil)
        #expect(LinkMetadataParser.parse(html: "<p>nothing</p>", baseURL: base) == LinkMetadata())
        #expect(LinkMetadataParser.defaultFaviconURL(for: base)?.absoluteString == "https://example.com/favicon.ico")
    }

    @Test func decodesEntities() {
        let html = "<meta property='og:title' content='Fish &amp; Chips &#8211; &#x1F41F; &quot;hi&quot; &unknown;'>"
        let m = LinkMetadataParser.parse(html: html, baseURL: base)
        #expect(m.title == "Fish & Chips \u{2013} \u{1F41F} \"hi\" &unknown;")
    }

    @Test func prefersAppleTouchIconAndLargestSize() {
        let html = """
        <link rel="icon" href="/16.png" sizes="16x16">
        <link rel="apple-touch-icon" href="/60.png" sizes="60x60">
        <link rel="apple-touch-icon" href="/180.png" sizes="180x180">
        <link rel="mask-icon" href="/mask.svg">
        """
        #expect(LinkMetadataParser.parse(html: html, baseURL: base).iconURL?.path == "/180.png")
    }

    @Test func ignoresScriptsCommentsAndNonHttpURLs() {
        let html = """
        <!-- <meta property="og:title" content="commented"> -->
        <script>var s = '<meta property="og:title" content="script">';</script>
        <meta property="og:image" content="javascript:alert(1)">
        <meta property="og:image:url" content="data:image/png;base64,AAAA">
        <title>Real</title>
        """
        let m = LinkMetadataParser.parse(html: html, baseURL: base)
        #expect(m.title == "Real")
        #expect(m.imageURL == nil)
    }

    @Test func survivesGarbage() {
        let junk = ["", "<<<<>>>>", "<meta", "<meta property=\"og:title\" content=\"unterminated",
                    "<title>", "&&&&;;;&#99999999999;", String(repeating: "<meta ", count: 2000),
                    "\u{0}\u{1}<link rel=icon href=>"]
        for j in junk { _ = LinkMetadataParser.parse(html: j, baseURL: base) }
        #expect(LinkMetadataParser.parse(html: "<meta property=og:title content=Plain>", baseURL: base).title == "Plain")
    }

    @Test func truncatesLongTitles() {
        let m = LinkMetadataParser.parse(html: "<title>\(String(repeating: "a", count: 1000))</title>", baseURL: base)
        #expect(m.title?.count == LinkMetadataParser.maxTitleLength)
    }
}

@Suite struct LinkPreviewPolicyTests {
    func ok(_ s: String) -> Bool { LinkPreviewPolicy.isFetchable(URL(string: s)!) }

    @Test func allowsOrdinaryPublicURLs() {
        #expect(ok("https://example.com/docs?page=2&q=swift"))
        #expect(ok("http://news.ycombinator.com/item?id=1"))
        #expect(ok("https://8.8.8.8/"))
        #expect(ok("https://example.com/#section"))
    }

    @Test func rejectsNonHttpAndCredentials() {
        #expect(!ok("ftp://example.com/x"))
        #expect(!ok("file:///etc/passwd"))
        #expect(!ok("https://user:pw@example.com/"))
        #expect(!ok("https://user@example.com/"))
    }

    @Test func rejectsInternalHosts() {
        for u in ["http://localhost:3000", "http://app.localhost/", "http://printer.local/", "http://intranet/",
                  "http://nas.lan/", "https://foo.internal/", "http://127.0.0.1/", "http://10.1.2.3/",
                  "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.1.1/", "http://169.254.169.254/",
                  "http://100.64.0.1/", "http://0.0.0.0/", "http://[::1]/", "http://2130706433/", "http://0x7f.1/"] {
            #expect(!ok(u), "\(u) should be skipped")
        }
        #expect(ok("http://172.32.0.1/"))
    }

    @Test func rejectsSecretLookingQueries() {
        for u in ["https://x.com/a?token=abc", "https://x.com/a?access_token=abc", "https://x.com/a?api_key=1",
                  "https://x.com/a?apiKey=1", "https://x.com/a?key=1", "https://x.com/a?secret=1",
                  "https://x.com/a?Password=1", "https://x.com/a?X-Amz-Signature=1", "https://x.com/a?sig=1",
                  "https://x.com/cb#access_token=abc&state=1", "https://x.com/a?id=1&auth=2"] {
            #expect(!ok(u), "\(u) should be skipped")
        }
        #expect(ok("https://x.com/a?keyword=swift&monkey=1&utm_source=x"))
    }
}

@Suite struct LinkPreviewStoreTests {
    func link(_ s: String) -> ClipItem {
        ClipItem(kind: .link, text: s, contentHash: ClipStore.hash(Data(s.utf8)))
    }

    @Test func savesAndSurvivesDedupe() throws {
        let store = try ClipStore(path: nil)
        let saved = try store.save(link("https://example.com"))
        #expect(saved.linkFetchedAt == nil)
        let ok = try store.saveLinkPreview(id: saved.id!, title: "Example", imagePath: "/tmp/a.png", imageIsIcon: true)
        #expect(ok)
        let again = try store.save(link("https://example.com")) // re-copy: bumps, keeps metadata
        #expect(again.linkTitle == "Example")
        #expect(again.linkImagePath == "/tmp/a.png")
        #expect(again.linkImageIsIcon == true)
        #expect(again.linkFetchedAt != nil)
        #expect(try store.items().count == 1)
    }

    @Test func failedFetchStillMarksAttempt() throws {
        let store = try ClipStore(path: nil)
        let saved = try store.save(link("https://example.com"))
        try store.saveLinkPreview(id: saved.id!, title: nil, imagePath: nil)
        let item = try store.item(id: saved.id!)
        #expect(item?.linkFetchedAt != nil)
        #expect(item?.linkTitle == nil)
        #expect(item?.linkImageIsIcon == nil)
    }

    @Test func missingClipReturnsFalse() throws {
        let store = try ClipStore(path: nil)
        #expect(try store.saveLinkPreview(id: 999, title: "x", imagePath: nil) == false)
    }

    @Test func pruningRemovesOldPreviewImagesButKeepsClipAndTitle() throws {
        let store = try ClipStore(path: nil)
        let old = try store.save(link("https://old.example.com"))
        let fresh = try store.save(link("https://new.example.com"))
        let longAgo = Date().addingTimeInterval(-40 * 86400)
        try store.saveLinkPreview(id: old.id!, title: "Old", imagePath: "old.png", fetchedAt: longAgo)
        try store.saveLinkPreview(id: fresh.id!, title: "New", imagePath: "new.png")
        let removed = try store.pruneLinkPreviewImages(olderThan: Date().addingTimeInterval(-30 * 86400))
        #expect(removed == ["old.png"])
        #expect(try store.items().count == 2)
        let o = try store.item(id: old.id!)
        #expect(o?.linkTitle == "Old")
        #expect(o?.linkImagePath == nil)
        #expect(try store.item(id: fresh.id!)?.linkImagePath == "new.png")
    }
}
