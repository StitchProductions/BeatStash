import Foundation

public enum JobStatus: String, Codable, Sendable {
    case pending
    case fetching
    case queued
    case downloading
    case tagging
    case completed
    case failed
    case cancelled

    public var isActive: Bool {
        self == .queued || self == .downloading || self == .tagging || self == .fetching
    }

    public var isFinished: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

/// One downloadable track (or occasional video).
public struct DownloadJob: Identifiable, Codable, Sendable {
    public var id: UUID
    public var url: String
    public var kind: DownloadKind

    // Batch context
    public var playlistTitle: String?
    public var playlistIndex: Int?

    // User-visible
    public var displayTitle: String
    public var thumbnailURL: String?
    public var duration: Double?

    /// Spotify (or other source) artwork to embed at tag time, replacing any
    /// YouTube thumbnail. Nil = keep whatever the download embedded.
    public var artworkURL: String? = nil

    // Format selection
    public var audioFormat: AudioFormat
    public var videoQuality: VideoQuality
    public var isFormatOverridden: Bool

    // Tags
    public var tags: TrackTags
    public var tagsEdited: Bool

    // Progress / state (not persisted across launches except history)
    public var status: JobStatus
    public var progress: Double // 0...1
    public var speedString: String?
    public var etaString: String?
    public var errorMessage: String?
    public var outputPath: String?
    public var selected: Bool // playlist checkbox

    public init(
        id: UUID = UUID(),
        url: String,
        kind: DownloadKind = .audio,
        playlistTitle: String? = nil,
        playlistIndex: Int? = nil,
        displayTitle: String,
        thumbnailURL: String? = nil,
        duration: Double? = nil,
        artworkURL: String? = nil,
        audioFormat: AudioFormat = .m4a,
        videoQuality: VideoQuality = .hd1080p,
        isFormatOverridden: Bool = false,
        tags: TrackTags = TrackTags(),
        tagsEdited: Bool = false,
        status: JobStatus = .pending,
        progress: Double = 0,
        selected: Bool = true
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.playlistTitle = playlistTitle
        self.playlistIndex = playlistIndex
        self.displayTitle = displayTitle
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.artworkURL = artworkURL
        self.audioFormat = audioFormat
        self.videoQuality = videoQuality
        self.isFormatOverridden = isFormatOverridden
        self.tags = tags
        self.tagsEdited = tagsEdited
        self.status = status
        self.progress = progress
        self.selected = selected
    }

    public var durationString: String {
        guard let duration else { return "–" }
        let total = Int(duration)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Persisted history row (completed downloads).
public struct HistoryEntry: Identifiable, Codable, Sendable {
    public var id: UUID
    public var date: Date
    public var title: String
    public var artist: String
    public var url: String
    public var format: String
    public var filePath: String
    public var thumbnailURL: String?

    public init(id: UUID = UUID(), date: Date = Date(), title: String, artist: String, url: String, format: String, filePath: String, thumbnailURL: String? = nil) {
        self.id = id
        self.date = date
        self.title = title
        self.artist = artist
        self.url = url
        self.format = format
        self.filePath = filePath
        self.thumbnailURL = thumbnailURL
    }
}
