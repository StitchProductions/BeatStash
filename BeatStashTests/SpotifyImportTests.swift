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

    // MARK: - Handoff search URLs (first result wins, no scoring)

    @Test func searchURLShapes() {
        #expect(SpotifyImportStore.searchURL(artist: "Adele", title: "Hello") == "ytsearch1:Adele Hello")
        #expect(SpotifyImportStore.searchURL(artist: "", title: "Hello") == "ytsearch1:Hello")
        #expect(SpotifyImportStore.searchURL(artist: "  ", title: "  Hello  ") == "ytsearch1:Hello")
        // Blank queries are skipped by handoff — never a bare "ytsearch1:".
        #expect(SpotifyImportStore.searchURL(artist: "", title: "") == "")
        #expect(SpotifyImportStore.searchURL(artist: "  ", title: "  ") == "")
        // Reserved chars pass through verbatim (argv, no shell escaping).
        #expect(SpotifyImportStore.searchURL(artist: "AC/DC", title: "Hells Bells") == "ytsearch1:AC/DC Hells Bells")
        #expect(SpotifyImportStore.searchURL(artist: "A&B", title: "C? D") == "ytsearch1:A&B C? D")
    }

}
