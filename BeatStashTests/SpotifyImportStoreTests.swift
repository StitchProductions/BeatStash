import Foundation
import Testing
@testable import BeatStash

/// Import-list lifecycle: Clear all removes imported tracks but keeps input.
@MainActor
struct SpotifyImportStoreTests {
    private func storeWithTracks() -> SpotifyImportStore {
        let store = SpotifyImportStore()
        store.urlText = "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"
        store.tracks = [
            SpotifyImportTrack(id: "a", title: "One", artist: "A"),
            SpotifyImportTrack(id: "b", title: "Two", artist: "B"),
        ]
        store.playlistTitle = "Some Playlist"
        store.errorMessage = "stale error"
        return store
    }

    @Test func clearTracksResetsListKeepsInput() {
        let store = storeWithTracks()
        store.clearTracks()
        #expect(store.tracks.isEmpty)
        #expect(store.playlistTitle == nil)
        #expect(store.errorMessage == nil)
        #expect(store.progress == nil)
        #expect(!store.isImporting)
        // Pasted link stays so the import can be edited and re-run.
        #expect(store.urlText == "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")
    }

    @Test func clearTracksOnEmptyStateIsNoop() {
        let store = SpotifyImportStore()
        store.clearTracks()
        #expect(store.tracks.isEmpty)
        #expect(store.playlistTitle == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func handoffEmitsSearchURLs() {
        let imports = SpotifyImportStore()
        imports.playlistTitle = "Some Playlist"
        var a = SpotifyImportTrack(id: "a", title: "Hello", artist: "Adele",
                                   artworkURL: "https://example.com/a.jpg")
        a.deezerDuration = 367
        a.status = .resolved
        a.selected = true
        var b = SpotifyImportTrack(id: "b", title: "Skip", artist: "Nobody")
        b.status = .working // still resolving: never addable
        b.selected = true
        imports.tracks = [a, b]
        let store = DownloadStore()
        #expect(imports.addSelectedToBatch(store) == 1)
        #expect(store.draftJobs.count == 1)
        let draft = store.draftJobs[0]
        #expect(draft.url == "ytsearch1:Adele Hello")
        #expect(draft.duration == 367)
        #expect(draft.artworkURL == "https://example.com/a.jpg")
        #expect(draft.tags.album == "Some Playlist")
        #expect(store.probeTitle == "Some Playlist")
    }
}
