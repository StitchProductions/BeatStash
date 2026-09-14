import Foundation

/// MusicBrainz anchor: independent duration cross-check, ISRCs, and curated
/// YouTube links (`url-rels`) — exact where present. Strictly throttled:
/// serial use only, ≥1.1s between requests, contact UA, skip-on-503.
/// Every failure degrades silently to the tiers below (never throws outward).
public struct MBRecording: Sendable {
    public var id: String // MBID
    public var title: String
    public var lengthSeconds: Double?
    public var isrcs: [String]

    public init(id: String, title: String, lengthSeconds: Double?, isrcs: [String]) {
        self.id = id
        self.title = title
        self.lengthSeconds = lengthSeconds
        self.isrcs = isrcs
    }
}

/// Recording search hit (internal for fixture tests — shapes per
/// MusicBrainz WS2 docs, re-verify against live responses on integration).
struct MBSearchEnvelope: Decodable {
    struct Hit: Decodable {
        var id: String?
        var title: String?
        var length: Double? // ms
        var score: Int?
        var isrcs: [String]?
    }
    var recordings: [Hit]?
}

/// `url-rels` include (internal for fixture tests).
struct MBRelationsEnvelope: Decodable {
    struct Relation: Decodable {
        struct Target: Decodable { var resource: String? }
        var url: Target?
    }
    var relations: [Relation]?
}

public enum MusicBrainzClient: Sendable {
    private static let base = "https://musicbrainz.org/ws/2"
    private static let userAgent = "BeatStash/1.0 ( https://github.com/anomalyco/opencode )"
    private static let minInterval: TimeInterval = 1.1

    /// Serial pacing gate (actor, not a lock — locks can't block async contexts).
    private actor PaceState {
        var lastRequest = Date.distantPast
        func waitTurn(minInterval: TimeInterval) async {
            let wait = minInterval - Date().timeIntervalSince(lastRequest)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            lastRequest = Date()
        }
    }
    private static let pace = PaceState()

    /// Serial pacing gate. Call before every request.
    private static func paceWait() async {
        await pace.waitTurn(minInterval: minInterval)
    }

    private static func get(_ path: String, query: [URLQueryItem]) async -> Data? {
        await paceWait()
        var comps = URLComponents(string: base + path)!
        comps.queryItems = query + [URLQueryItem(name: "fmt", value: "json")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Top recording hit with length + ISRCs, or nil.
    public static func searchRecording(artist: String, title: String) async -> MBRecording? {
        guard let data = await get("/recording/", query: [
            URLQueryItem(name: "query", value: "recording:\(title) AND artist:\(artist)"),
            URLQueryItem(name: "limit", value: "3"),
        ]) else { return nil }
        guard let hits = try? JSONDecoder().decode(MBSearchEnvelope.self, from: data).recordings,
              let top = hits.max(by: { ($0.score ?? 0) < ($1.score ?? 0) }),
              let id = top.id, let title = top.title
        else { return nil }
        return MBRecording(id: id, title: title,
                           lengthSeconds: top.length.map { $0 / 1000 },
                           isrcs: top.isrcs ?? [])
    }

    /// Curated `youtube.com/watch` URLs linked to the recording (usually
    /// 0–1). Exact matches when present.
    public static func youtubeURLs(mbid: String) async -> [String] {
        guard let data = await get("/recording/\(mbid)/", query: [
            URLQueryItem(name: "inc", value: "url-rels"),
        ]) else { return [] }
        guard let rels = try? JSONDecoder().decode(MBRelationsEnvelope.self, from: data).relations else { return [] }
        var seen = Set<String>()
        return rels.compactMap(\.url?.resource).filter { r in
            guard let u = URL(string: r),
                  u.host?.contains("youtube.com") == true || u.host?.contains("youtu.be") == true,
                  seen.insert(r).inserted else { return false }
            return true
        }
    }
}
