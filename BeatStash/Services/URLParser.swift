import Foundation

/// Validates + normalizes YouTube URLs. Public/unlisted only in v1
/// (no cookie/auth support for private playlists).
public enum URLParser: Sendable {
    public enum Kind: Sendable, Equatable {
        case video
        case playlist
        case shorts
        case unknown
    }

    /// Split pasted text into candidate URLs (one per line, also comma/space separated).
    public nonisolated static func extractURLs(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: "\n,")
        let chunks = text.components(separatedBy: separators)
            .flatMap { $0.components(separatedBy: .whitespaces) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Keep http(s) or bare video IDs (11 chars).
        return chunks.filter { isYouTubeURL($0) || isBareVideoID($0) }
            .map { normalize($0) }
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
        isYouTubeURL(s) || isBareVideoID(s)
    }
}
