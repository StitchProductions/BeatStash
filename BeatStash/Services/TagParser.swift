import Foundation

/// Offline parser: YouTube `title` + `uploader` → clean `TrackTags`.
/// No network, no API key. Pure function — unit-testable.
public enum TagParser: Sendable {
    // Suffixes that add noise, not identity. `feat.` is deliberately kept.
    // Precompiled once — stripNoise() runs per track (100s per playlist).
    // Immutable after first use: safe from any isolation.
    nonisolated private static let noiseRegexes: [NSRegularExpression] = [
        #"\s*[\(\[]\s*official\s*(music\s*)?(video|audio|visualizer|lyric(s)?|mv)?\s*[\)\]]"#,
        #"\s*[\(\[]\s*(official\s*)?(lyric(s)?\s*(video|visualizer)?|audio|visualizer|music\s*video|m/?v)\s*[\)\]]"#,
        #"\s*[\(\[]\s*(HD|4K|HQ)\s*[\)\]]"#,
        #"\s+-\s*(HD|4K|HQ)\s*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    nonisolated private static let separators = [" - ", " – ", " — ", " –", " —", " : "]

    public nonisolated static func parse(
        title: String,
        uploader: String?,
        playlistTitle: String? = nil,
        playlistIndex: Int? = nil,
        uploadDate: String? = nil
    ) -> TrackTags {
        let cleanedTitle = stripNoise(title).trimmingCharacters(in: .whitespaces)
        var artist = ""
        var songTitle = cleanedTitle

        if let sep = separators.first(where: { cleanedTitle.contains($0) }) {
            let parts = cleanedTitle.components(separatedBy: sep)
            if parts.count >= 2 {
                artist = parts[0].trimmingCharacters(in: .whitespaces)
                songTitle = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            }
        }

        if artist.isEmpty {
            artist = cleanUploader(uploader ?? "")
        } else {
            artist = artist.trimmingCharacters(in: .whitespaces)
        }

        // If title ended up empty (e.g. "Artist - "), fall back to raw.
        if songTitle.isEmpty { songTitle = cleanedTitle }

        let album: String
        if let pl = playlistTitle?.trimmingCharacters(in: .whitespaces), !pl.isEmpty {
            album = pl
        } else {
            album = "Single"
        }

        var year: String?
        if let d = uploadDate, d.count >= 4 {
            year = String(d.prefix(4))
        }

        return TrackTags(
            artist: artist,
            title: songTitle,
            album: album,
            trackNumber: playlistIndex,
            year: year,
            genre: nil
        )
    }

    // MARK: - Helpers

    public nonisolated static func stripNoise(_ s: String) -> String {
        var out = s
        for re in noiseRegexes {
            out = re.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: ""
            )
        }
        // Collapse double spaces left behind.
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// "LoyleCarnerVEVO" → "LoyleCarner", "Adele - Topic" → "Adele".
    public nonisolated static func cleanUploader(_ uploader: String) -> String {
        var u = uploader.trimmingCharacters(in: .whitespaces)
        if u.hasSuffix("VEVO") { u = String(u.dropLast(4)) }
        if let range = u.range(of: " - Topic", options: .caseInsensitive) {
            u = String(u[..<range.lowerBound])
        }
        u = u.replacingOccurrences(of: "Official", with: "", options: .caseInsensitive)
        return u.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
