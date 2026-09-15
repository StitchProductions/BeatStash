import Foundation
import Testing
@testable import BeatStash

/// Spotify import: link parsing, anchor fixtures, matcher scoring.
/// Network clients degrade silently by contract — only pure shapes tested here.
@MainActor
struct SpotifyImportTests {
    // MARK: - Link parsing

    @Test func playlistURLs() {
        #expect(SpotifyService.parseLink(
            "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")?.id == "37i9dQZF1DXcBWIGoYBM5M")
        #expect(SpotifyService.parseLink(
            "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc")?.id == "37i9dQZF1DXcBWIGoYBM5M")
        #expect(SpotifyService.parseLink(
            "https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M")?.id == "37i9dQZF1DXcBWIGoYBM5M")
        #expect(SpotifyService.parseLink("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")?.id == "37i9dQZF1DXcBWIGoYBM5M")
    }

    @Test func trackURLs() {
        #expect(SpotifyService.parseLink(
            "https://open.spotify.com/track/3h5T5JypYU7huFiVYhv1dr")?.id == "3h5T5JypYU7huFiVYhv1dr")
        #expect(SpotifyService.parseLink("spotify:track:3h5T5JypYU7huFiVYhv1dr")?.id == "3h5T5JypYU7huFiVYhv1dr")
    }

    @Test func linkKinds() {
        let pl = SpotifyService.parseLink("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")
        #expect(pl?.kind == .playlist)
        let tr = SpotifyService.parseLink("https://open.spotify.com/track/3h5T5JypYU7huFiVYhv1dr")
        #expect(tr?.kind == .track)
    }

    @Test func garbageRejected() {
        #expect(SpotifyService.parseLink("hello world") == nil)
        #expect(SpotifyService.parseLink("https://www.youtube.com/watch?v=x") == nil)
        #expect(SpotifyService.parseLink("spotify:album:abc") == nil)
        #expect(SpotifyService.parseLink("https://open.spotify.com/playlist/short") == nil)
    }

    // MARK: - Embed parsing

    @Test func trackIDsExtractedDeduped() {
        let html = """
            <div>spotify:track:AAAAAAAAAAAAAAAAAAAAAA spotify:track:BBBBBBBBBBBBBBBBBBBBBB
            spotify:track:AAAAAAAAAAAAAAAAAAAAAA</div>
            """
        #expect(SpotifyService.extractTrackIDs(from: html)
            == ["AAAAAAAAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBBBBBBBB"])
    }

    @Test func playlistNameFixture() {
        let html = """
            <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"name":"My Mix"}}}}}}</script>
            """
        #expect(SpotifyService.extractPlaylistName(from: html) == "My Mix")
        #expect(SpotifyService.extractPlaylistName(from: "<html></html>") == nil)
    }

    // MARK: - Anchor fixtures

    @Test func deezerFixture() throws {
        let t = try JSONDecoder().decode(DeezerTrack.self, from: Data("""
            {"title":"Despacito","duration":228,
             "artist":{"name":"Luis Fonsi"},"album":{"title":"VIDA"}}
            """.utf8))
        #expect(t.title == "Despacito")
        #expect(t.artistName == "Luis Fonsi")
        #expect(t.albumName == "VIDA")
        #expect(t.duration == 228)
    }

    // MARK: - Matcher

    private func candidate(title: String, uploader: String, duration: Double?) -> PlaylistEntry {
        PlaylistEntry(id: "v-\(title.prefix(4))", title: title, url: nil,
                      duration: duration, thumbnail: nil, uploader: uploader,
                      playlistIndex: nil, playlistTitle: nil)
    }

    @Test func exactMatchScoresHigh() {
        let s = YouTubeMatcher.score(
            artist: "Luis Fonsi", title: "Despacito", anchorDuration: 228,
            candidate: candidate(title: "Luis Fonsi - Despacito ft. Daddy Yankee",
                                 uploader: "Luis Fonsi", duration: 282))
        #expect(s >= YouTubeMatcher.autoSelectThreshold)
    }

    @Test func loopDecoyRejected() {
        let s = YouTubeMatcher.score(
            artist: "Luis Fonsi", title: "Despacito", anchorDuration: 228,
            candidate: candidate(title: "Despacito 1 Hour Loop", uploader: "Random",
                                 duration: 3600))
        #expect(s < YouTubeMatcher.autoSelectThreshold)
    }

    @Test func wrongSongScoresZero() {
        let s = YouTubeMatcher.score(
            artist: "Luis Fonsi", title: "Despacito", anchorDuration: 228,
            candidate: candidate(title: "Shape of You", uploader: "Ed Sheeran",
                                 duration: 263))
        #expect(s < 0.2)
    }

    @Test func unanchoredStillWorks() {
        let s = YouTubeMatcher.score(
            artist: "Queen", title: "Bohemian Rhapsody", anchorDuration: nil,
            candidate: candidate(title: "Queen – Bohemian Rhapsody (Official Video)",
                                 uploader: "Queen Official", duration: 360))
        #expect(s >= YouTubeMatcher.autoSelectThreshold)
    }

    @Test func queryAndNorm() {
        #expect(YouTubeMatcher.query(artist: "Luis Fonsi", title: "Despacito") == "Luis Fonsi Despacito")
        #expect(YouTubeMatcher.norm("Hello (Official Video)") == "hello")
    }

    @Test func videoIDExtraction() {
        #expect(YouTubeMatcher.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeMatcher.videoID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeMatcher.videoID(from: "not a url") == nil)
    }

    @Test func matchCacheRoundTripAndTTL() throws {
        let dir = try TestHelpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        YouTubeMatcher.matchCacheFileOverride = dir.appendingPathComponent("match-cache.json")
        defer { YouTubeMatcher.matchCacheFileOverride = nil }

        #expect(YouTubeMatcher.readMatchCache().isEmpty)
        let fresh = CachedMatch(youtubeID: "abc123XYZ_-", score: 0.87,
                                youtubeTitle: "T", duration: 200, exact: false)
        YouTubeMatcher.writeMatchCache(["spotify:track1": fresh])
        let back = YouTubeMatcher.readMatchCache()
        #expect(back["spotify:track1"]?.youtubeID == "abc123XYZ_-")
        #expect(back["spotify:track1"]?.score == 0.87)

        // Expired entries prune on read.
        var stale = back
        stale["old"] = CachedMatch(youtubeID: "z", score: 1, youtubeTitle: "O",
                                   duration: nil, exact: true,
                                   at: Date(timeIntervalSince1970: 0))
        YouTubeMatcher.writeMatchCache(stale)
        let pruned = YouTubeMatcher.readMatchCache()
        #expect(pruned["old"] == nil)
        #expect(pruned["spotify:track1"] != nil)
    }

    // MARK: - Handoff search URLs (first result wins, no scoring)

    @Test func searchURLShapes() {
        #expect(SpotifyImportStore.searchURL(artist: "Adele", title: "Hello") == "ytsearch1:Adele Hello")
        #expect(SpotifyImportStore.searchURL(artist: "", title: "Hello") == "ytsearch1:Hello")
        #expect(SpotifyImportStore.searchURL(artist: "  ", title: "  Hello  ") == "ytsearch1:Hello")
    }

}
