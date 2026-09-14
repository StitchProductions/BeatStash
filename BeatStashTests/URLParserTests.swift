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
