import Foundation

/// YouTube authentication + anti-bot configuration (v1.1).
///
/// Three independent layers — cookies prove *who you are*, player-client
/// selection and PO-tokens prove *where the request comes from*.
/// Supplying one does nothing for the other, so they compose:
///
/// 1. Cookies (`--cookies` / `--cookies-from-browser`) — required for
///    age-restricted, members-only, private videos. Use a throwaway
///    Google account; sessions used by downloaders get flagged.
/// 2. Player-client fallback chains — different clients get different
///    challenges. `android` first for anonymous probes (works without
///    credentials); `default,web_embedded` when cookies are present
///    (`tv` + cookies invalidates the session — never pair them).
/// 3. PO-token provider plugin (optional) — `mweb` + generated token for
///    SABR-gated formats. Auto-enabled only when a JS runtime
///    (`deno`/`node`) and `Resources/plugins` are present; otherwise the
///    app gracefully falls back to clients that need no token.
///
/// Persisted in UserDefaults; the cookies.txt copy lives in
/// `~/Library/Application Support/BeatStash/` with `0600` permissions.
public struct YouTubeAuth: Codable, Sendable, Equatable {
    public enum CookieMode: String, Codable, Sendable, CaseIterable, Identifiable {
        case off
        case browser
        case file

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .off: return "Off (anonymous)"
            case .browser: return "Read from browser"
            case .file: return "cookies.txt file"
            }
        }
    }

    public var cookieMode: CookieMode
    public var browser: String // firefox | chrome | brave | edge | safari
    public var cookieFilePath: String? // managed copy in Application Support
    public var manualPoToken: String // raw `web.gvs+...` value for debugging
    /// Measured ~30% faster probes (broken/slow IPv6 stalls every request).
    /// Default on; the Settings toggle still opts out.
    public var forceIPv4: Bool

    public init(
        cookieMode: CookieMode = .off,
        browser: String = "firefox",
        cookieFilePath: String? = nil,
        manualPoToken: String = "",
        forceIPv4: Bool = true
    ) {
        self.cookieMode = cookieMode
        self.browser = browser
        self.cookieFilePath = cookieFilePath
        self.manualPoToken = manualPoToken
        self.forceIPv4 = forceIPv4
    }

    public var hasCookies: Bool {
        switch cookieMode {
        case .off: return false
        case .browser: return !browser.isEmpty
        case .file:
            guard let p = cookieFilePath, !p.isEmpty else { return false }
            return FileManager.default.isReadableFile(atPath: p)
        }
    }

    // MARK: - Persistence

    private static let prefix = "ytAuth."

    public static func load(defaults: UserDefaults = .standard) -> YouTubeAuth {
        var auth = YouTubeAuth()
        if let raw = defaults.string(forKey: prefix + "cookieMode"),
           let m = CookieMode(rawValue: raw) { auth.cookieMode = m }
        if let b = defaults.string(forKey: prefix + "browser"), !b.isEmpty { auth.browser = b }
        auth.cookieFilePath = defaults.string(forKey: prefix + "cookieFile")
        auth.manualPoToken = defaults.string(forKey: prefix + "poToken") ?? ""
        auth.forceIPv4 = defaults.object(forKey: prefix + "forceIPv4") as? Bool ?? true
        // Self-heal: file mode pointing at a deleted file == off.
        if auth.cookieMode == .file && !auth.hasCookies { auth.cookieMode = .off }
        return auth
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(cookieMode.rawValue, forKey: Self.prefix + "cookieMode")
        defaults.set(browser, forKey: Self.prefix + "browser")
        defaults.set(cookieFilePath, forKey: Self.prefix + "cookieFile")
        defaults.set(manualPoToken, forKey: Self.prefix + "poToken")
        defaults.set(forceIPv4, forKey: Self.prefix + "forceIPv4")
    }

    // MARK: - yt-dlp argument builders (pure, testable)

    /// Auth-only flags, shared by probe + download invocations.
    public func authArgs() -> [String] {
        var args: [String] = []
        switch cookieMode {
        case .off: break
        case .browser:
            if !browser.isEmpty { args += ["--cookies-from-browser", browser] }
        case .file:
            if let p = cookieFilePath, !p.isEmpty,
               FileManager.default.isReadableFile(atPath: p) {
                args += ["--cookies", p]
            }
        }
        let token = manualPoToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { args += ["--extractor-args", "youtube:po_token=\(token)"] }
        if forceIPv4 { args += ["--force-ipv4"] }
        return args
    }

    /// Ordered player-client chains to try. First success wins — even a
    /// format-gated success (360p-only) counts for probing, since metadata
    /// is intact. Chains are ordered cheapest-first.
    ///
    /// Verified 2026-09-14 against `youtu.be/5tBG5f3EQNc`:
    /// `android,ios,tv` extracts; `tv,web_safari` → "needs reload";
    /// `mweb`/`web_safari` alone → "format not available".
    public func clientChains() -> [[String]] {
        if hasCookies {
            // Never tv+cookies: TV auth differs and invalidates the session.
            return [
                ["default", "web_embedded"],
                ["web_safari"],
                ["mweb"],
            ]
        }
        return [
            ["android", "ios", "tv"],
            ["web_embedded"],
            ["tv", "web_safari"],
        ]
    }

    public static func clientArgs(for chain: [String]) -> [String] {
        ["--extractor-args", "youtube:player_client=\(chain.joined(separator: ","))"]
    }

    // MARK: - Shared network hardening (probe + download)

    public static var networkArgs: [String] {
        [
            "--socket-timeout", "15",
            "--retries", "2",
            "--extractor-retries", "2",
            "--fragment-retries", "2",
            "--sleep-interval", "1",
            "--max-sleep-interval", "5",
        ]
    }

    // MARK: - Cookies.txt import

    /// Copies a user-picked `cookies.txt` (Netscape format) into
    /// Application Support with owner-only permissions.
    @discardableResult
    public static func importCookiesFile(from source: URL) throws -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dest = base.appendingPathComponent("cookies.txt")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return dest.path
    }

    public static func clearCookiesFile() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash/cookies.txt")
        try? FileManager.default.removeItem(at: base)
    }
}
