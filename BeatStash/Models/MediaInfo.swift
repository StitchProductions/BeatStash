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
        case id, title, uploader, channel, duration, thumbnail
        case webpageURL = "webpage_url"
        case uploadDate = "upload_date"
        case playlistTitle = "playlist_title"
        case playlistIndex = "playlist_index"
        case type = "_type"
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
public enum ProbeResult: Sendable {
    case single(MediaInfo)
    case playlist(title: String?, entries: [PlaylistEntry])
}
