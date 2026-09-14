import Foundation
import Testing
@testable import BeatStash

/// Instant tier: `youtube.com/oembed` (~0.15s, no auth). Title/author/thumb
/// only — duration and date backfill from the full probe.
@MainActor
struct OEmbedTests {
    private func decodeVideo(_ json: String) throws -> OEmbedVideo {
        try JSONDecoder().decode(OEmbedVideo.self, from: Data(json.utf8))
    }

    @Test func videoFixtureDecodes() throws {
        let v = try decodeVideo("""
            {"title":"Luis Fonsi - Despacito ft. Daddy Yankee",
             "author_name":"LuisFonsiVEVO",
             "author_url":"https://www.youtube.com/@LuisFonsiVEVO",
             "type":"video","thumbnail_url":"https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg"}
            """)
        #expect(v.title == "Luis Fonsi - Despacito ft. Daddy Yankee")
        #expect(v.authorName == "LuisFonsiVEVO")
        #expect(v.thumbnailURL?.contains("kJQP7kiw5Fk") == true)
    }

    @Test func playlistFixtureDecodes() throws {
        // Playlists answer with a title/author too (entries still need the probe).
        let v = try decodeVideo("""
            {"title":"Blender Open Movies","author_name":"Blender Studio","type":"video"}
            """)
        #expect(v.title == "Blender Open Movies")
        #expect(v.thumbnailURL == nil)
    }

    @Test func endpointShape() {
        let url = YTDLPService.oEmbedURL(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(url?.host == "www.youtube.com")
        #expect(url?.path == "/oembed")
        #expect(url?.query?.contains("format=json") == true)
        #expect(YTDLPService.oEmbedURL(for: "not a url %%") == nil)
        // Well-formed non-YouTube URLs still build (YouTube 404s them;
        // fetchOEmbed's non-200 check turns that into the normal fallback).
        #expect(YTDLPService.oEmbedURL(for: "https://example.com/x") != nil)
    }

    @Test func draftMapping() {
        let video = try! decodeVideo(#"{"title":"Adele - Hello (Official Music Video)","author_name":"AdeleVEVO"}"#)
        let job = DownloadStore.draftFromOEmbed(
            url: "https://www.youtube.com/watch?v=YQHsXMglC9A", video: video,
            format: .mp3, quality: .hd1080p, mode: .audio)
        #expect(job.displayTitle == "Hello")
        #expect(job.tags.artist == "Adele")
        #expect(job.duration == nil) // backfills from the full probe
        #expect(job.audioFormat == .mp3)
        #expect(job.kind == .audio)
    }

    @Test func draftMappingKeepsUntitledEdge() {
        let video = try! decodeVideo(#"{"title":"(Official Video)","author_name":"U"}"#)
        let job = DownloadStore.draftFromOEmbed(
            url: "https://example.com/x", video: video,
            format: .m4a, quality: .hd1080p, mode: .audio)
        #expect(!job.displayTitle.isEmpty)
    }
}
