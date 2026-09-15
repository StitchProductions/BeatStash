import Foundation

/// Persistent per-track match outcomes, keyed by stable Spotify track ID
/// (immune to renames, shared across playlists). Playlist membership itself
/// is never cached — always re-fetched live — so added/removed songs always
/// reflect while known tracks skip re-searching entirely.
public struct CachedMatch: Codable, Sendable {
    public var youtubeID: String
    public var score: Double
    public var youtubeTitle: String
    public var duration: Double?
    public var exact: Bool
    public var at: Date

    public init(youtubeID: String, score: Double, youtubeTitle: String,
                duration: Double?, exact: Bool, at: Date = Date()) {
        self.youtubeID = youtubeID
        self.score = score
        self.youtubeTitle = youtubeTitle
        self.duration = duration
        self.exact = exact
        self.at = at
    }
}

/// Spotify → YouTube matching utilities: query building, candidate
/// scoring, and the persistent match cache. All pure (`nonisolated`) and
/// headless-testable; network lives in `YTDLPService.searchYouTube`
/// and `DeezerClient`.
///
/// Score weights (0...1, auto-select at `autoSelectThreshold`):
/// token-overlap base + artist-authority bonus + duration-anchor window
/// − loop/live penalties. Duration uses a generous window: official videos
/// routinely run ~60s past the audio (outros), while fakes run 10x long.
public enum YouTubeMatcher: Sendable {
    public static let autoSelectThreshold = 0.5

    /// Match outcomes live 30 days: recordings don't move. Failures are never
    /// cached (transient by nature).
    static nonisolated let matchCacheTTL: TimeInterval = 30 * 24 * 3600
    static nonisolated let matchCacheCap = 2000

    /// Test seam: redirect the cache file.
    nonisolated(unsafe) static var matchCacheFileOverride: URL?

    nonisolated static func matchCacheFile() -> URL {
        matchCacheFileOverride ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash/match-cache.json", isDirectory: false)
    }

    /// Reads + TTL-prunes. Pure file I/O (`nonisolated`) so `swift-testing`
    /// `#expect` doesn't wrap same-actor sync calls in a needless `await`.
    nonisolated static func readMatchCache() -> [String: CachedMatch] {
        guard let data = try? Data(contentsOf: matchCacheFile()) else { return [:] }
        guard var cache = try? JSONDecoder().decode([String: CachedMatch].self, from: data) else { return [:] }
        cache = cache.filter { Date().timeIntervalSince($0.value.at) < matchCacheTTL }
        return cache
    }

    /// Prunes (TTL + cap) and persists.
    nonisolated static func writeMatchCache(_ cache: [String: CachedMatch]) {
        var pruned = cache.filter { Date().timeIntervalSince($0.value.at) < matchCacheTTL }
        if pruned.count > matchCacheCap {
            let newest = pruned.sorted { $0.value.at > $1.value.at }.prefix(matchCacheCap)
            pruned = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        try? FileManager.default.createDirectory(
            at: matchCacheFile().deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pruned) {
            try? data.write(to: matchCacheFile(), options: .atomic)
        }
    }

    /// `"Artist Title"` for `ytsearchN:` (artist-first matches best).
    nonisolated public static func query(artist: String, title: String) -> String {
        "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
    }

    /// Normalized comparison form: noise-stripped, lowercase, alphanumeric words.
    nonisolated public static func norm(_ s: String) -> String {
        TagParser.stripNoise(s).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// YouTube video ID from watch/shorts/embed/youtu.be URLs.
    nonisolated public static func videoID(from youtubeURL: String) -> String? {
        guard let u = URL(string: youtubeURL) else { return nil }
        if u.host?.contains("youtu.be") == true {
            let id = u.pathComponents.first { $0 != "/" }
            return id
        }
        return URLComponents(url: u, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value
    }

    /// Composite score. `anchorDuration` = Deezer seconds (nil when
    /// unanchored — title/channel signals alone).
    nonisolated public static func score(
        artist: String, title: String,
        anchorDuration: Double?,
        candidate: PlaylistEntry
    ) -> Double {
        let qArtist = norm(artist)
        let qTitle = norm(title)
        let cTitle = norm(candidate.title ?? "")
        let cUp = norm(candidate.uploader ?? "")
        let qTokens = Set((qArtist + " " + qTitle).split(separator: " ").map(String.init))
            .filter { !$0.isEmpty }
        let cTokens = Set((cTitle + " " + cUp).split(separator: " ").map(String.init))
            .filter { !$0.isEmpty }
        var s: Double = 0
        if !qTokens.isEmpty, !cTokens.isEmpty {
            let inter = qTokens.intersection(cTokens).count
            s = 2 * Double(inter) / Double(qTokens.count + cTokens.count)
        }
        // Exact normalized title (with or without artist prefix).
        if !qTitle.isEmpty,
           cTitle == qTitle || (!qArtist.isEmpty && cTitle == "\(qArtist) \(qTitle)") {
            s = max(s, 0.95)
        }
        // Authority: the artist's own upload/channel.
        if !qArtist.isEmpty, cUp.contains(qArtist) || cTitle.contains(qArtist) {
            s += 0.15
        }
        // Penalties for wrong-version tells (unless the query claims them).
        let ql = (artist + " " + title).lowercased()
        if !ql.contains("live"), cTitle.contains("live") { s -= 0.15 }
        if !ql.contains("loop"),
           cTitle.contains("1 hour") || cTitle.contains("10 hours")
            || cTitle.contains("loop") {
            s -= 0.3
        }
        // Duration anchor: generous window, harsh only on gross mismatch.
        if let anchor = anchorDuration, let d = candidate.duration {
            let diff = abs(d - anchor)
            if diff <= 5 { s += 0.1 }
            else if diff <= 15 { s += 0.05 }
            else if diff > 90 { s -= 0.25 }
        }
        return min(max(s, 0), 1)
    }
}
