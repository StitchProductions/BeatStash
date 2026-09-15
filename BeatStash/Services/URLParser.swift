import Foundation

/// Validates + normalizes YouTube URLs and ytsearch queries.
/// Public/unlisted only in v1 (private items need cookies via Settings).
public enum URLParser: Sendable {
    public enum Kind: Sendable, Equatable {
        case video
        case playlist
        case shorts
        case unknown
    }

    /// Split pasted text into candidate URLs (one per line, also comma/space separated).
    /// `ytsearchN:` lines keep their spaces — the query is the whole line
    /// (Spotify handoff drafts resolve at fetch time).
    public nonisolated static func extractURLs(from text: String) -> [String] {
        var out: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if isSearchURL(line) {
                out.append(line)
                continue
            }
            let chunks = line.components(separatedBy: ",")
                .flatMap { $0.components(separatedBy: .whitespaces) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // Keep http(s) or bare video IDs (11 chars).
            out += chunks.filter { isYouTubeURL($0) || isBareVideoID($0) }
                .map { normalize($0) }
        }
        return out
    }

    /// `ytsearch1:artist title` query URL (Spotify handoff). The query runs
    /// to the end of the line — never split on its spaces.
    public nonisolated static func isSearchURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard let colon = lower.firstIndex(of: ":") else { return false }
        let scheme = String(lower[..<colon])
        guard scheme.hasPrefix("ytsearch") else { return false }
        return scheme.dropFirst("ytsearch".count).allSatisfy(\.isNumber)
    }

    public nonisolated static func isBareVideoID(_ s: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return s.count == 11 && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public nonisolated static func isYouTubeURL(_ s: String) -> Bool {
        guard let url = URL(string: s.lowercased()), url.scheme?.hasPrefix("http") == true else { return false }
        let host = url.host ?? ""
        return host.contains("youtube.com") || host.contains("youtu.be") || host.contains("music.youtube.com")
    }

    public nonisolated static func normalize(_ s: String) -> String {
        if isBareVideoID(s) { return "https://www.youtube.com/watch?v=\(s)" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public nonisolated static func kind(of urlString: String) -> Kind {
        let lower = urlString.lowercased()
        if lower.contains("list=") || lower.contains("/playlist") { return .playlist }
        if lower.contains("/shorts/") { return .shorts }
        if lower.contains("watch") || lower.contains("youtu.be") || lower.contains("music.youtube") { return .video }
        return .unknown
    }

    public nonisolated static func isPlausiblySupported(_ s: String) -> Bool {
        isYouTubeURL(s) || isBareVideoID(s) || isSearchURL(s)
    }
}
