import Foundation

/// Clean, editable song tags derived from YouTube metadata.
/// Source: offline parse of `title` + `uploader` (+ playlist context).
public struct TrackTags: Codable, Sendable, Equatable {
    public var artist: String
    public var title: String
    public var album: String
    public var trackNumber: Int?
    public var year: String?
    public var genre: String?

    public init(
        artist: String = "",
        title: String = "",
        album: String = "",
        trackNumber: Int? = nil,
        year: String? = nil,
        genre: String? = nil
    ) {
        self.artist = artist
        self.title = title
        self.album = album
        self.trackNumber = trackNumber
        self.year = year
        self.genre = genre
    }

    /// Display "Artist – Title", falling back gracefully.
    public var displayLine: String {
        if !artist.isEmpty && !title.isEmpty { return "\(artist) – \(title)" }
        return title.isEmpty ? artist : title
    }

    public var isEmpty: Bool {
        artist.isEmpty && title.isEmpty
    }
}
