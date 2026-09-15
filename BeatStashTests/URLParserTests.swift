import Foundation
import Testing
@testable import BeatStash

@MainActor
struct URLParserTests {
    @Test func watchURLPassesThrough() {
        let u = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        #expect(URLParser.extractURLs(from: u) == [u])
    }

    @Test func multilineAndCommaSeparated() {
        let text = """
            https://www.youtube.com/watch?v=dQw4w9WgXcQ
            https://youtu.be/9bZkp7q19f0, https://www.youtube.com/watch?v=kJQP7kiw5Fk
            """
        #expect(URLParser.extractURLs(from: text) == [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/9bZkp7q19f0",
            "https://www.youtube.com/watch?v=kJQP7kiw5Fk",
        ])
    }

    @Test func bareVideoIDNormalizes() {
        #expect(URLParser.extractURLs(from: "dQw4w9WgXcQ")
            == ["https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
    }

    @Test func garbageRejected() {
        #expect(URLParser.extractURLs(from: "hello world").isEmpty)
        #expect(URLParser.extractURLs(from: "https://example.com/x").isEmpty)
        #expect(URLParser.extractURLs(from: "   \n  ").isEmpty)
    }

    @Test func searchQueryKeepsWholeLine() {
        // Spotify handoff queries carry spaces — splitting would drop them.
        #expect(URLParser.extractURLs(from: "ytsearch1:Adele Hello") == ["ytsearch1:Adele Hello"])
        #expect(URLParser.isSearchURL("ytsearch1:Adele Hello"))
        #expect(URLParser.isSearchURL("YTSEARCH5:x"))
        #expect(!URLParser.isSearchURL("https://www.youtube.com/watch?v=x"))
        #expect(!URLParser.isSearchURL("hello world"))
        // Mixed paste: search lines survive alongside normal links.
        #expect(URLParser.extractURLs(from: "ytsearch1:Adele Hello\nhttps://youtu.be/9bZkp7q19f0")
            == ["ytsearch1:Adele Hello", "https://youtu.be/9bZkp7q19f0"])
        #expect(URLParser.isPlausiblySupported("ytsearch1:Adele Hello"))
    }

    @Test func searchURLNeverAPlaylist() {
        // A query containing "list=" must not route into the flat-playlist probe.
        #expect(!YTDLPService.isListURL("ytsearch1:best playlist hits 2026"))
        #expect(YTDLPService.isListURL("https://www.youtube.com/playlist?list=PLx"))
    }

    @Test func elevenCharWordIsIDShaped() {
        // By design: any 11-char base64-ish token is treated as a video ID.
        #expect(URLParser.isBareVideoID("abcdefghijk"))
        #expect(!URLParser.isBareVideoID("too short"))
    }

    @Test func kindDetection() {
        #expect(URLParser.kind(of: "https://www.youtube.com/watch?v=x") == .video)
        #expect(URLParser.kind(of: "https://youtu.be/x") == .video)
        #expect(URLParser.kind(of: "https://www.youtube.com/playlist?list=PLx") == .playlist)
        #expect(URLParser.kind(of: "https://www.youtube.com/watch?v=x&list=PLy") == .playlist)
        #expect(URLParser.kind(of: "https://www.youtube.com/shorts/abc") == .shorts)
        #expect(URLParser.kind(of: "https://example.com/") == .unknown)
    }
}
