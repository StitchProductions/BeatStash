import Foundation

/// Canonical metadata anchor: title/artist/album/duration with no key.
/// Verified live (~0.3s). No ISRC field — duration + spelling are the signals.
public struct DeezerTrack: Sendable, Decodable {
    public var title: String
    public var artistName: String
    public var albumName: String?
    public var duration: Int? // seconds

    private struct Artist: Decodable { var name: String? }
    private struct Album: Decodable { var title: String? }

    enum CodingKeys: String, CodingKey {
        case title, duration, artist, album
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        duration = try? c.decode(Int.self, forKey: .duration)
        artistName = (try? c.decode(Artist.self, forKey: .artist))?.name ?? ""
        albumName = (try? c.decode(Album.self, forKey: .album))?.title
    }
}

public enum DeezerClient: Sendable {
    private actor MemoStore {
        var memo: [String: (track: DeezerTrack?, at: Date)] = [:]
        func get(_ key: String) -> DeezerTrack?? {
            guard let hit = memo[key], Date().timeIntervalSince(hit.at) < 600 else { return nil }
            return .some(hit.track)
        }
        func set(_ key: String, track: DeezerTrack?) {
            if memo.count > 500 { memo.removeAll() }
            memo[key] = (track, Date())
        }
    }
    private static let store = MemoStore()

    /// Top search hit, or nil (never throws — absence just leaves the
    /// duration/album anchor empty).
    /// Session memo (10 min): re-imports and auto-retries never re-query the
    /// same `artist + title`.
    public static func search(artist: String, title: String) async -> DeezerTrack? {
        let key = "\(artist.lowercased())\0\(title.lowercased())"
        if let hit = await store.get(key) { return hit }
        let found = await searchUncached(artist: artist, title: title)
        await store.set(key, track: found)
        return found
    }

    private static func searchUncached(artist: String, title: String) async -> DeezerTrack? {
        var comps = URLComponents(string: "https://api.deezer.com/search")!
        comps.queryItems = [URLQueryItem(
            name: "q", value: "\(artist) \(title)".trimmingCharacters(in: .whitespaces))]
        guard let url = comps.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(
                for: URLRequest(url: url, timeoutInterval: 10))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            struct Envelope: Decodable {
                var data: [DeezerTrack]?
            }
            return try? JSONDecoder().decode(Envelope.self, from: data).data?.first
        } catch {
            return nil
        }
    }
}
