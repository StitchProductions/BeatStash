import Foundation

/// Audio container choices. All use `--audio-quality 0` (best).
/// Note: YouTube sources are lossy (Opus ~160k / AAC ~128k).
/// FLAC/WAV are transcoded containers — DAW-ready, larger, no extra fidelity.
public enum AudioFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case opus
    case m4a
    case mp3
    case flac
    case wav

    public var id: String { rawValue }

    /// yt-dlp `--audio-format` value.
    public nonisolated var ytDlpValue: String {
        switch self {
        case .opus: return "opus"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        case .flac: return "flac"
        case .wav: return "wav"
        }
    }

    public nonisolated var displayName: String {
        switch self {
        case .opus: return "Opus (true best)"
        case .m4a: return "M4A"
        case .mp3: return "MP3 320"
        case .flac: return "FLAC"
        case .wav: return "WAV"
        }
    }

    public nonisolated var fileExtension: String {
        switch self {
        case .opus: return "opus"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        case .flac: return "flac"
        case .wav: return "wav"
        }
    }

    /// Approximate MB per minute, for batch size estimates.
    public nonisolated var mbPerMinute: Double {
        switch self {
        case .opus: return 1.2
        case .m4a: return 1.5
        case .mp3: return 2.4
        case .flac: return 7.0
        case .wav: return 10.0
        }
    }

    public nonisolated var isLosslessContainer: Bool {
        self == .flac || self == .wav
    }

    public nonisolated var footnote: String? {
        switch self {
        case .wav:
            return "WAV is DAW-ready but large (~10 MB/min). Source is still YouTube-quality. WAV can't carry cover art (text tags only)."
        case .flac:
            return "FLAC is a lossless container of a lossy source — larger, same fidelity."
        default:
            return nil
        }
    }
}

/// Occasional-video presets. Kept minimal in v1 (MP4 only).
public enum VideoQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case hd1080p
    case uhd4k

    public var id: String { rawValue }

    public nonisolated var displayName: String {
        switch self {
        case .hd1080p: return "1080p MP4"
        case .uhd4k: return "4K MP4"
        }
    }

    /// Max height for `bv*[height<=H]` selector.
    public nonisolated var maxHeight: Int {
        switch self {
        case .hd1080p: return 1080
        case .uhd4k: return 2160
        }
    }
}

/// Download mode for a job.
public enum DownloadKind: String, Codable, Sendable {
    case audio
    case video
}
