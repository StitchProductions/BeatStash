import Foundation
import Testing
@testable import BeatStash

/// Fixture tolerance: YouTube changes `--dump-json` shape frequently, so
/// unknown keys must decode past and missing keys must surface as nil.
@MainActor
struct MediaDecodeTests {
    private func decodeMedia(_ json: String) throws -> MediaInfo {
        try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
    }

    @Test func fullDumpDecodes() throws {
        let m = try decodeMedia("""
            {"id":"kJQP7kiw5Fk","title":"Despacito","uploader":"Luis Fonsi",
             "duration":282,"thumbnail":"https://i.ytimg.com/vi/x/hq.jpg",
             "webpage_url":"https://www.youtube.com/watch?v=kJQP7kiw5Fk",
             "upload_date":"20170113","formats":[{"format_id":"18"}],
             "some_future_field":{"nested":true}}
            """)
        #expect(m.id == "kJQP7kiw5Fk")
        #expect(m.safeTitle == "Despacito")
        #expect(m.safeUploader == "Luis Fonsi")
        #expect(m.duration == 282)
        #expect(m.year == "2017")
    }

    @Test func emptyObjectIsSafe() throws {
        let m = try decodeMedia("{}")
        #expect(m.safeTitle == "Unknown title")
        #expect(m.safeUploader == "")
        #expect(m.year == nil)
        #expect(m.durationString == "–")
        #expect(m.formats == nil) // absent key: unknown, never an error
    }

    @Test func channelFallsBackForUploader() throws {
        let m = try decodeMedia(#"{"id":"x","channel":"SomeChannel"}"#)
        #expect(m.safeUploader == "SomeChannel")
    }

    @Test func flatEntryWithPlaylistTitle() throws {
        let e = try JSONDecoder().decode(PlaylistEntry.self, from: Data("""
            {"id":"abc123","title":"T","url":"https://www.youtube.com/watch?v=abc123",
             "playlist_title":"My List","playlist_index":3}
            """.utf8))
        #expect(e.playlistTitle == "My List")
        #expect(e.playlistIndex == 3)
        #expect(e.webpageURL == "https://www.youtube.com/watch?v=abc123")
    }

    @Test func flatEntryWithoutPlaylistFields() throws {
        let e = try JSONDecoder().decode(PlaylistEntry.self, from: Data("""
            {"id":"abc123","title":"T"}
            """.utf8))
        #expect(e.playlistTitle == nil)
        #expect(e.playlistIndex == nil)
        #expect(e.safeTitle == "T")
        // Bare IDs still resolve to a watch URL.
        #expect(e.webpageURL == "https://www.youtube.com/watch?v=abc123")
    }

    @Test func flatBlobParses() {
        let blob = """
            {"id":"a","title":"One","playlist_title":"L","playlist_index":1}
            {"id":"b","title":"Two","playlist_title":"L","playlist_index":2}
            """
        let entries = YTDLPService.parseFlatEntries(from: blob)
        #expect(entries?.count == 2)
        #expect(entries?.first?.playlistTitle == "L")
    }

    @Test func flatBlobWithoutIndexIsSingle() {
        #expect(YTDLPService.parseFlatEntries(from: #"{"id":"a","title":"One"}"#) == nil)
        #expect(YTDLPService.parseFlatEntries(from: "") == nil)
    }
}
