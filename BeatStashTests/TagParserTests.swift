import Foundation
import Testing
@testable import BeatStash

@MainActor
struct TagParserTests {
    @Test func artistDashTitle() {
        let t = TagParser.parse(title: "Luis Fonsi - Despacito ft. Daddy Yankee", uploader: "LuisFonsiVEVO")
        #expect(t.artist == "Luis Fonsi")
        #expect(t.title == "Despacito ft. Daddy Yankee") // feat. is identity, kept
        #expect(t.album == "Single")
        #expect(t.trackNumber == nil)
    }

    @Test func officialVideoNoiseStripped() {
        let t = TagParser.parse(title: "Adele - Hello (Official Music Video)", uploader: "AdeleVEVO")
        #expect(t.artist == "Adele")
        #expect(t.title == "Hello")
    }

    @Test func noSeparatorFallsBackToUploader() {
        let t = TagParser.parse(title: "Never Gonna Give You Up", uploader: "RickAstleyVEVO")
        #expect(t.artist == "RickAstley")
        #expect(t.title == "Never Gonna Give You Up")
    }

    @Test func yearFromUploadDate() {
        let t = TagParser.parse(title: "Song", uploader: "U", uploadDate: "20151023")
        #expect(t.year == "2015")
        let none = TagParser.parse(title: "Song", uploader: "U")
        #expect(none.year == nil)
    }

    @Test func playlistBecomesAlbum() {
        let t = TagParser.parse(title: "Track", uploader: "U", playlistTitle: "My List", playlistIndex: 3)
        #expect(t.album == "My List")
        #expect(t.trackNumber == 3)
    }

    @Test func cleanUploader() {
        #expect(TagParser.cleanUploader("LoyleCarnerVEVO") == "LoyleCarner")
        #expect(TagParser.cleanUploader("Adele - Topic") == "Adele")
    }

    @Test func stripNoise() {
        #expect(TagParser.stripNoise("Song (Official Music Video)") == "Song")
        #expect(TagParser.stripNoise("Song (Lyric Video)") == "Song")
        #expect(TagParser.stripNoise("Song (4K Remaster)") == "Song (4K Remaster)") // not noise
    }
}
