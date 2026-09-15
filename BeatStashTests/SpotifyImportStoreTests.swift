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
}
