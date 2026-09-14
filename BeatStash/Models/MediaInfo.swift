import Foundation

/// Minimal subset of `yt-dlp --dump-json` we rely on.
/// All fields optional — YouTube changes shape frequently.
public struct MediaInfo: Codable, Sendable {
    public var id: String?
    public var title: String?
    public var uploader: String?
    public var channel: String?
    public var duration: Double?
    public var thumbnail: String?
    public var webpageURL: String?
    public var uploadDate: String? // yyyyMMdd
    public var playlistTitle: String?
    public var playlistIndex: Int?

    /// `_type`: "video" | "playlist" | "compat_list"
    public var type: String?

    /// Format list (only when the dump includes it). All-optional: SABR-gated
    /// dumps omit URLs, flat entries omit formats entirely — absence means
    /// "unknown", never an error.
    public var formats: [ProbeFormat]?

    public var isPlaylist: Bool {
        type == "playlist" || type == "compat_list"
    }

    public var safeTitle: String { title ?? id ?? "Unknown title" }
    public var safeUploader: String { uploader ?? channel ?? "" }

    /// Year from `upload_date` (yyyyMMdd → yyyy).
    public var year: String? {
        guard let d = uploadDate, d.count >= 4 else { return nil }
        return String(d.prefix(4))
    }

    public var durationString: String {
        guard let duration else { return "–" }
        let total = Int(duration)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, uploader, channel, duration, thumbnail, formats
        case webpageURL = "webpage_url"
        case uploadDate = "upload_date"
        case playlistTitle = "playlist_title"
        case playlistIndex = "playlist_index"
        case type = "_type"
    }
}

/// One format entry. Deliberately minimal: only what download planning needs
/// (a usable stream URL). Everything optional for SABR-era dumps.
public struct ProbeFormat: Codable, Sendable {
    public var formatID: String?
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case url
    }
}

/// One entry from `--flat-playlist --dump-json` (line-delimited JSON).
public struct PlaylistEntry: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var url: String?
    public var duration: Double?
    public var thumbnail: String?
    public var uploader: String?
    public var playlistIndex: Int?
    /// Playlist-level title echoed into flat entries by yt-dlp (may be absent).
    public var playlistTitle: String?

    public var webpageURL: String {
        if let url, url.hasPrefix("http") { return url }
        return "https://www.youtube.com/watch?v=\(id)"
    }

    public var safeTitle: String { title ?? id }

    public var durationString: String {
        guard let duration else { return "–" }
        let total = Int(duration)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, url, duration, thumbnail, uploader
        case playlistIndex = "playlist_index"
        case playlistTitle = "playlist_title"
    }
}

/// Result of probing a URL: single video or playlist.
public enum ProbeResult: Sendable, Codable {
    case single(MediaInfo)
    case playlist(title: String?, entries: [PlaylistEntry])

    private enum Kind: String, Codable { case single, playlist }
    private enum Keys: String, CodingKey { case kind, title, media, entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .single:
            self = .single(try c.decode(MediaInfo.self, forKey: .media))
        case .playlist:
            self = .playlist(
                title: try c.decodeIfPresent(String.self, forKey: .title),
                entries: try c.decode([PlaylistEntry].self, forKey: .entries))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .single(let media):
            try c.encode(Kind.single, forKey: .kind)
            try c.encode(media, forKey: .media)
        case .playlist(let title, let entries):
            try c.encode(Kind.playlist, forKey: .kind)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encode(entries, forKey: .entries)
        }
    }
}

/// Minimal `youtube.com/oembed` response — the instant metadata tier.
/// Official endpoint, no auth, ~0.15s. No duration/date: those backfill.
public struct OEmbedVideo: Decodable, Sendable {
    public var title: String
    public var authorName: String
    public var thumbnailURL: String?
    public var authorURL: String?

    enum CodingKeys: String, CodingKey {
        case title
        case authorName = "author_name"
        case thumbnailURL = "thumbnail_url"
        case authorURL = "author_url"
    }
}
