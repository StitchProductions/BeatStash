import Foundation

/// One Spotify track reference: ID from the playlist, metadata from oEmbed.
public struct SpotifyTrack: Sendable, Identifiable {
    public var id: String // Spotify track ID (22-char base62)
    public var title: String
    public var artist: String
    public var artworkURL: String?

    public init(id: String, title: String, artist: String, artworkURL: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
    }
}

/// Keyless Spotify reading: public playlist/track pages only.
/// - Playlist/track IDs parsed from `open.spotify.com` + embed URLs/URIs.
/// - Playlist content via the embed page (`__NEXT_DATA__` → name + track URIs).
/// - Per-track metadata via the oEmbed endpoint (title/author/thumbnail).
/// No durations exist on any keyless surface — anchors come from Deezer,
/// candidate durations from YouTube itself.
public enum SpotifyService: Sendable {
    /// 22-char base62 Spotify IDs.
    public nonisolated static func isSpotifyID(_ s: String) -> Bool {
        s.count == 22 && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    public enum LinkKind: Sendable, Equatable { case playlist, track }

    /// Accepts open/embed URLs and `spotify:` URIs. Returns kind + raw ID.
    public nonisolated static func parseLink(_ text: String) -> (kind: LinkKind, id: String)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("spotify:") {
            let parts = s.split(separator: ":")
            guard parts.count == 3 else { return nil }
            let kind = String(parts[1]), id = String(parts[2])
            guard isSpotifyID(id) else { return nil }
            if kind == "playlist" { return (.playlist, id) }
            if kind == "track" { return (.track, id) }
            return nil
        }
        guard let url = URL(string: s),
              url.host?.contains("spotify.com") == true else { return nil }
        // /playlist/<id>, /track/<id>, /embed/playlist/<id>, /embed/track/<id>
        let comps = url.pathComponents.filter { $0 != "/" }
        var kind: LinkKind?
        var id: String?
        var expectID = false
        for c in comps {
            if c == "embed" { continue }
            if c == "playlist" { kind = .playlist; expectID = true; continue }
            if c == "track" { kind = .track; expectID = true; continue }
            if expectID { id = c; break }
        }
        guard let kind, var id else { return nil }
        // Strip query-joined artifacts (defensive; pathComponents excludes queries already).
        if let q = id.firstIndex(of: "?") { id = String(id[..<q]) }
        guard isSpotifyID(id) else { return nil }
        return (kind, id)
    }

    private static let embedUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    /// Playlist name + track URIs from the embed page. Throws offline/blocked.
    /// Exposes whatever the endpoint lists (observed full 50/50; mega-lists
    /// may truncate — no pagination exists without API keys).
    public static func fetchPlaylist(id: String) async throws -> (name: String, trackIDs: [String]) {
        var req = URLRequest(
            url: URL(string: "https://open.spotify.com/embed/playlist/\(id)")!,
            timeoutInterval: 15)
        req.setValue(embedUA, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw SpotifyError.unreachable
        }
        let ids = extractTrackIDs(from: html)
        guard !ids.isEmpty else { throw SpotifyError.noTracks }
        return (extractPlaylistName(from: html) ?? "Spotify Playlist", ids)
    }

    /// Track URIs (`spotify:track:<id>`) in embed HTML, order-preserved, deduped.
    nonisolated static func extractTrackIDs(from html: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        var search = html[...]
        while let r = search.range(of: "spotify:track:") {
            let rest = search[r.upperBound...]
            let id = rest.prefix(22)
            if id.count == 22, isSpotifyID(String(id)), seen.insert(String(id)).inserted {
                out.append(String(id))
            }
            search = rest
        }
        return out
    }

    /// Playlist name from embed `__NEXT_DATA__`, nil when absent.
    nonisolated static func extractPlaylistName(from html: String) -> String? {
        guard let start = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let end = html[start.upperBound...].range(of: "</script>"),
              let data = String(html[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = json["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let dataObj = state["data"] as? [String: Any],
              let entity = dataObj["entity"] as? [String: Any],
              let name = entity["name"] as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    /// Per-track title/author/artwork via oEmbed (no duration anywhere keyless).
    public static func fetchTrackMeta(id: String) async throws -> SpotifyTrack {
        var comps = URLComponents(string: "https://open.spotify.com/oembed")!
        comps.queryItems = [
            URLQueryItem(name: "url", value: "https://open.spotify.com/track/\(id)"),
        ]
        guard let endpoint = comps.url else { throw SpotifyError.unreachable }
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: endpoint, timeoutInterval: 10))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SpotifyError.unreachable
        }
        struct OEmbed: Decodable {
            var title: String
            var author_name: String?
            var thumbnail_url: String?
        }
        guard let o = try? JSONDecoder().decode(OEmbed.self, from: data) else {
            throw SpotifyError.unparseable
        }
        return SpotifyTrack(id: id, title: o.title,
                            artist: o.author_name ?? "",
                            artworkURL: o.thumbnail_url)
    }

    public enum SpotifyError: LocalizedError, Sendable {
        case unreachable
        case noTracks
        case unparseable

        public var errorDescription: String? {
            switch self {
            case .unreachable: return "Couldn't reach Spotify (playlist must be public)."
            case .noTracks: return "No tracks found — is the playlist public?"
            case .unparseable: return "Spotify changed its page format."
            }
        }
    }
}
