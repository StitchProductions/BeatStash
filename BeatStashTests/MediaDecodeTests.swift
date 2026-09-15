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

    @Test func flatBlobCarriesThumbnailsArray() {
        let blob = """
            {"id":"a","title":"One","playlist_title":"L","playlist_index":1,"thumbnails":[{"url":"https://example.com/a-small.jpg","width":168},{"url":"https://example.com/a-big.jpg","width":336}]}
            """
        let entries = YTDLPService.parseFlatEntries(from: blob)
        #expect(entries?.first?.resolvedThumbnail == "https://example.com/a-big.jpg")
    }

    @Test func artlessCachedPlaylistReprobes() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeatStashTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        YTDLPService.diskCacheFileOverride = dir.appendingPathComponent("probe-cache.json")
        defer { YTDLPService.diskCacheFileOverride = nil }
        func writeCache(_ entriesJSON: String) {
            let at = String(data: try! JSONEncoder().encode(Date()), encoding: .utf8)!
            try! """
            {"https://www.youtube.com/playlist?list=PLtest":{"at":\(at),"result":{"kind":"playlist","title":"L","entries":\(entriesJSON)}}}
            """.write(to: YTDLPService.diskCacheFileOverride!, atomically: true, encoding: .utf8)
        }
        // Old-style entry (cached before thumbnails[] support): miss → re-probe.
        writeCache(#"[{"id":"a","title":"One","playlist_index":1}]"#)
        #expect(await YTDLPService().diskCachedProbe(
            for: "https://www.youtube.com/playlist?list=PLtest") == nil)
        // New-style entry carrying art: hit.
        writeCache(#"[{"id":"a","title":"One","playlist_index":1,"thumbnails":[{"url":"https://example.com/a.jpg","width":336}]}]"#)
        let hit = await YTDLPService().diskCachedProbe(
            for: "https://www.youtube.com/playlist?list=PLtest")
        if case .playlist(_, let entries)? = hit {
            #expect(entries.first?.resolvedThumbnail == "https://example.com/a.jpg")
        } else {
            Issue.record("expected a cached playlist hit")
        }
    }

    @Test func flatBlobWithoutIndexIsSingle() {
        #expect(YTDLPService.parseFlatEntries(from: #"{"id":"a","title":"One"}"#) == nil)
        #expect(YTDLPService.parseFlatEntries(from: "") == nil)
    }

    @Test func flatEntryThumbnailsArrayResolves() {
        // Real `--flat-playlist` shape: plural `thumbnails[]`, no singular key.
        let e = try! JSONDecoder().decode(PlaylistEntry.self, from: Data("""
            {"id":"ekr2nIex040","title":"APT.","playlist_title":"Pop",
             "playlist_index":1,
             "thumbnails":[{"url":"https://i.ytimg.com/vi/ekr2nIex040/hqdefault.jpg","width":168,"height":94},
                           {"url":"https://i.ytimg.com/vi/ekr2nIex040/maxresdefault.jpg","width":336,"height":188}]}
            """.utf8))
        #expect(e.thumbnail == nil)
        #expect(e.resolvedThumbnail == "https://i.ytimg.com/vi/ekr2nIex040/maxresdefault.jpg")
    }

    @Test func singularThumbnailWinsOverArray() {
        let e = try! JSONDecoder().decode(PlaylistEntry.self, from: Data("""
            {"id":"x","thumbnail":"https://example.com/single.jpg",
             "thumbnails":[{"url":"https://example.com/big.jpg","width":640}]}
            """.utf8))
        #expect(e.resolvedThumbnail == "https://example.com/single.jpg")
    }

    @Test func dimensionlessThumbnailsResolveToLast() {
        let e = try! JSONDecoder().decode(PlaylistEntry.self, from: Data("""
            {"id":"x","thumbnails":[{"url":"https://example.com/a.jpg"},
                                    {"url":"https://example.com/b.jpg"}]}
            """.utf8))
        #expect(e.resolvedThumbnail == "https://example.com/b.jpg")
    }

    @Test func noThumbnailsResolvesNil() {
        let e = try! JSONDecoder().decode(PlaylistEntry.self, from: Data("""
            {"id":"x","title":"T"}
            """.utf8))
        #expect(e.resolvedThumbnail == nil)
    }

    @Test func mediaInfoThumbnailsArrayResolves() {
        let m = try! JSONDecoder().decode(MediaInfo.self, from: Data("""
            {"id":"x","thumbnails":[{"url":"https://example.com/a.jpg","width":120}]}
            """.utf8))
        #expect(m.resolvedThumbnail == "https://example.com/a.jpg")
    }
}
