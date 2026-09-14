import Foundation
import os

/// Locates `yt-dlp`, `ffmpeg`, `ffprobe` with zero-setup UX.
///
/// Search order for yt-dlp:
/// 1. Settings custom override (user-managed, never auto-updated)
/// 2. `~/Library/Application Support/BeatStash/bin/` (self-updating copy)
/// 3. `Bundle.main/Resources/bin/` (shipped snapshot, always present in releases)
/// 4. Homebrew + `/usr/local/bin` + `PATH` (`which`) — last-resort fallback only
///
/// Updates are delivered by downloading the standalone `yt-dlp_macos` asset
/// from GitHub into Application Support — never by modifying the app bundle
/// (the bundle is read-only once signed, and in-place self-update would break
/// the code signature). No Homebrew or separate install is ever required.
public actor BinaryManager: Sendable {
    public static let shared = BinaryManager()

    // MARK: - Release channels

    public enum Channel: String, Sendable, CaseIterable {
        case stable
        case nightly

        public var displayName: String {
            switch self {
            case .stable: return "Stable"
            case .nightly: return "Nightly"
            }
        }

        /// GitHub API endpoint for the newest release on this channel.
        var apiURL: URL {
            switch self {
            case .stable:
                return URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
            case .nightly:
                return URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp-nightly-builds/releases/latest")!
            }
        }

        var assetName: String { "yt-dlp_macos" }
    }

    /// Where the active yt-dlp copy came from (shown in Settings).
    public enum BinarySource: Sendable {
        case custom
        case support
        case bundled
        case system
        case missing

        public var displayName: String {
            switch self {
            case .custom: return "Custom path"
            case .support: return "Auto-updated copy"
            case .bundled: return "Bundled with app"
            case .system: return "System install"
            case .missing: return "Not found"
            }
        }
    }

    public struct UpdateCheck: Sendable {
        public var current: String?
        public var latest: String
        public var available: Bool
        public var channel: Channel
    }

    /// Non-throwing outcome for the Settings button and launch auto-update.
    public enum UpdateOutcome: Sendable {
        case upToDate(version: String)
        case updated(from: String?, to: String)
        case skipped(reason: String)
        case failed(message: String)
    }

    public static let channelKey = "ytDlpChannel"
    static let lastCheckKey = "ytDlpLastCheck"
    static let lastKnownLatestKey = "ytDlpLastKnownLatest"
    /// First-launch acceptance of mandatory yt-dlp auto-updates.
    public static let termsKey = "ytDlpTermsAccepted"
    /// Minimum interval between automatic (non-manual) update checks.
    static let checkInterval: TimeInterval = 24 * 3600

    private let fileManager = FileManager.default

    private nonisolated static let log = Logger(
        subsystem: "StitchProductions.BeatStash", category: "binaries")

    /// Per-process `which()` memo (system paths don't change mid-launch).
    private var whichCache: [String: String?] = [:]
    /// `yt-dlp --version` memo, keyed by resolved path.
    private var cachedVersion: String?
    private var cachedVersionPath: String?

    public private(set) var ytDlpPath: String?
    public private(set) var ffmpegPath: String?
    public private(set) var ffprobePath: String?

    public var isReady: Bool { ytDlpPath != nil && ffmpegPath != nil }

    /// True when the user pinned a working custom binary (they manage updates).
    public func usesCustomOverride() -> Bool {
        if let custom = UserDefaults.standard.string(forKey: "customYtDlpPath"),
           !custom.isEmpty, fileManager.isExecutableFile(atPath: custom) {
            return true
        }
        return false
    }

    public func storedChannel() -> Channel {
        Channel(rawValue: UserDefaults.standard.string(forKey: Self.channelKey) ?? "") ?? .stable
    }

    public func setChannel(_ channel: Channel) {
        UserDefaults.standard.set(channel.rawValue, forKey: Self.channelKey)
    }

    public func lastCheckDate() -> Date? {
        let t = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    public func cachedLatestVersion() -> String? {
        UserDefaults.standard.string(forKey: Self.lastKnownLatestKey)
    }

    // MARK: - Locate

    /// Run on launch + when Settings changes. Returns true when yt-dlp found.
    ///
    /// The self-updating Application Support copy wins over the shipped
    /// snapshot so an in-app update is never shadowed by the bundle. The
    /// launch-time auto-update check converges it to latest, healing the
    /// edge where a fresh app install ships a newer snapshot than the
    /// previously downloaded copy.
    ///
    /// Fast path: Support + bundle are pure filesystem checks (no spawns).
    /// The slow brew/`PATH` scan (process spawns) runs only when both miss,
    /// and already-resolved results are reused unless `force` is set.
    @discardableResult
    public func locate(force: Bool = false) -> Bool {
        if !force,
           let yt = ytDlpPath, let ff = ffmpegPath,
           fileManager.isExecutableFile(atPath: yt),
           fileManager.isExecutableFile(atPath: ff) {
            return true
        }
        // 0. User override wins (and opts out of auto-updates).
        ytDlpPath = resolve(name: "yt-dlp", customKey: "customYtDlpPath",
                            systemFixed: ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"])
        ffmpegPath = resolve(name: "ffmpeg", customKey: "customFfmpegPath",
                             systemFixed: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"])
        ffprobePath = resolve(name: "ffprobe", customKey: nil,
                              systemFixed: ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"])

        Self.log.debug("""
            locate: yt-dlp=\(self.ytDlpPath ?? "nil", privacy: .public) \
            ffmpeg=\(self.ffmpegPath ?? "nil", privacy: .public) \
            ffprobe=\(self.ffprobePath ?? "nil", privacy: .public) \
            bundle=\(Bundle.main.resourceURL?.path ?? "nil", privacy: .public)
            """)
        return ytDlpPath != nil
    }

    /// Custom override → Support/bundled (fast, no spawns) → system scan (slow).
    private func resolve(name: String, customKey: String?, systemFixed: [String]) -> String? {
        if let key = customKey,
           let custom = UserDefaults.standard.string(forKey: key), !custom.isEmpty,
           fileManager.isExecutableFile(atPath: custom) {
            return custom
        }
        if let fast = firstExecutable(candidates: [supportBin(name)] + bundledCandidates(name: name)) {
            return fast
        }
        var slow = systemFixed
        if let w = which(name) { slow.append(w) }
        return firstExecutable(candidates: slow)
    }

    public func activeSource() -> BinarySource {
        guard let path = ytDlpPath else { return .missing }
        if let custom = UserDefaults.standard.string(forKey: "customYtDlpPath"),
           !custom.isEmpty, path == custom { return .custom }
        if path == supportBin("yt-dlp") { return .support }
        if bundledCandidates(name: "yt-dlp").contains(path) { return .bundled }
        return .system
    }

    // MARK: - First-launch install

    /// Installs the latest standalone `yt-dlp_macos` into Application Support
    /// if no usable copy exists anywhere (bundled, system, or custom).
    /// Throws with a human-readable message for the onboarding sheet.
    public func ensureYtDlp() async throws -> String {
        if let existing = ytDlpPath, fileManager.isExecutableFile(atPath: existing) {
            return existing
        }
        _ = locate()
        if let existing = ytDlpPath { return existing }

        let outcome = await checkAndUpdateIfNeeded(ignoreCache: true)
        switch outcome {
        case .updated(_, _), .upToDate:
            if let p = ytDlpPath { return p }
            throw BinaryError.missingYtDlp
        case .skipped(let reason):
            if let p = ytDlpPath { return p }
            throw BinaryError.downloadFailed(reason)
        case .failed(let message):
            throw BinaryError.downloadFailed(message)
        }
    }

    // MARK: - Version / update

    /// Memoized `--version` for the resolved path. Invalidated on install.
    public func ytDlpVersion() async -> String? {
        guard let path = ytDlpPath else { return nil }
        if path == cachedVersionPath, let v = cachedVersion { return v }
        let v = await versionOf(path: path)
        cachedVersionPath = path
        cachedVersion = v
        return v
    }

    public func invalidateVersionCache() {
        cachedVersion = nil
        cachedVersionPath = nil
    }

    public func ffmpegAvailable() -> Bool { ffmpegPath != nil }

    /// JS runtime yt-dlp can use for signature challenges / PO-token work.
    /// Prefers `deno`, falls back to `node`. Nil = neither installed.
    public func jsRuntimeName() -> String? {
        if which("deno") != nil { return "deno" }
        if which("node") != nil { return "node" }
        return nil
    }

    /// Bundled yt-dlp plugin directory (`Resources/plugins`), if shipped.
    /// Used for the optional PO-token provider plugin — absent = stock run.
    public func pluginDirectory() -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("plugins").path
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
            return dir
        }
        return nil
    }

    /// Parses `yt-dlp --version` (`2026.08.19`, nightly `2026.08.30.232658`)
    /// into a date for staleness checks (build suffix ignored).
    public func ytDlpReleaseDate() async -> Date? {
        guard let v = await ytDlpVersion() else { return nil }
        let parts = v.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    /// Days since the yt-dlp release date. Nil = unknown.
    public func ytDlpAgeDays() async -> Int? {
        guard let d = await ytDlpReleaseDate() else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }

    /// Compares dotted numeric versions (`2026.08.19` vs `2026.08.30.232658`).
    /// Longer-is-newer on an equal prefix, so nightlies sort after their day's stable.
    public nonisolated static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Remote release lookup

    private struct GitHubRelease: Decodable {
        var tagName: String
        var assets: [GitHubAsset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        var name: String
        var browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    /// Newest release tag + download URL on the given channel.
    /// Throws `BinaryError.downloadFailed` when offline or rate-limited.
    public func fetchLatestRelease(channel: Channel? = nil) async throws -> (tag: String, assetURL: URL) {
        let channel = channel ?? storedChannel()
        var request = URLRequest(url: channel.apiURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BinaryError.downloadFailed(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 429 {
                // Rate-limited: back off quietly instead of hammering.
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                throw BinaryError.downloadFailed("GitHub rate limit reached — will retry later.")
            }
            throw BinaryError.downloadFailed("GitHub API returned status \(code).")
        }
        do {
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let asset = release.assets.first(where: { $0.name == channel.assetName }) else {
                throw BinaryError.downloadFailed("No \(channel.assetName) asset in \(release.tagName).")
            }
            return (release.tagName, asset.browserDownloadURL)
        } catch let e as BinaryError {
            throw e
        } catch {
            throw BinaryError.downloadFailed("Couldn't parse release info.")
        }
    }

    /// Compares the active copy against the channel's latest release.
    /// Records the check timestamp + latest tag for caching and Settings display.
    /// The local version probe and the network lookup run concurrently.
    public func checkForUpdate() async throws -> UpdateCheck {
        let channel = storedChannel()
        async let currentVersion = ytDlpVersion()
        async let latestRelease = fetchLatestRelease(channel: channel)
        let (current, (tag, _)) = try await (currentVersion, latestRelease)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        UserDefaults.standard.set(tag, forKey: Self.lastKnownLatestKey)
        let available: Bool
        if let current {
            available = Self.compareVersions(current, tag) == .orderedAscending
        } else {
            available = true
        }
        return UpdateCheck(current: current, latest: tag, available: available, channel: channel)
    }

    /// Check-and-install entry point for both the launch auto-updater and the
    /// Settings Update button. Never throws — failures come back as `.failed`.
    /// - Parameter ignoreCache: bypass the 24h check interval (manual Update press).
    public func checkAndUpdateIfNeeded(ignoreCache: Bool = false) async -> UpdateOutcome {
        // A valid custom override means the user manages yt-dlp themselves.
        if let custom = UserDefaults.standard.string(forKey: "customYtDlpPath"),
           !custom.isEmpty, fileManager.isExecutableFile(atPath: custom) {
            ytDlpPath = custom
            return .skipped(reason: "Using your custom yt-dlp — updates are manual.")
        }
        if !ignoreCache, let last = lastCheckDate(),
           Date().timeIntervalSince(last) < Self.checkInterval {
            return .skipped(reason: "Checked recently.")
        }
        do {
            let check = try await checkForUpdate()
            guard check.available else {
                return .upToDate(version: check.current ?? check.latest)
            }
            let installed = try await install(channel: check.channel)
            return .updated(from: check.current, to: installed)
        } catch let e as BinaryError {
            return .failed(message: e.localizedDescription)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Reinstalls from `channel` regardless of the version comparison.
    /// Used when the user switches channels (a nightly can sort "newer"
    /// than the stable they just switched back to).
    public func reinstallFromChannel(_ channel: Channel) async -> UpdateOutcome {
        setChannel(channel)
        do {
            let (tag, _) = try await fetchLatestRelease(channel: channel)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            UserDefaults.standard.set(tag, forKey: Self.lastKnownLatestKey)
            let before = await ytDlpVersion()
            let installed = try await install(channel: channel)
            if let before, Self.compareVersions(before, installed) == .orderedSame {
                return .upToDate(version: installed)
            }
            return .updated(from: before, to: installed)
        } catch let e as BinaryError {
            return .failed(message: e.localizedDescription)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Downloads the channel's `yt-dlp_macos` asset into Application Support,
    /// verifies it executes, and swaps it atomically into place.
    /// Returns the installed version. The app bundle itself is never modified.
    private func install(channel: Channel) async throws -> String {
        let (_, assetURL) = try await fetchLatestRelease(channel: channel)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config)
        let tmpURL: URL
        do {
            (tmpURL, _) = try await session.download(from: assetURL)
        } catch {
            throw BinaryError.downloadFailed(error.localizedDescription)
        }
        let tmpPath = tmpURL.path

        // Size sanity: the standalone macOS binary is tens of MB.
        if let size = try? fileManager.attributesOfItem(atPath: tmpPath)[.size] as? NSNumber,
           size.intValue < 1_000_000 {
            try? fileManager.removeItem(atPath: tmpPath)
            throw BinaryError.downloadFailed("Download looks truncated (\(size.intValue) bytes).")
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
        // Strip quarantine so Gatekeeper doesn't block the verified download.
        _ = await runCapture("/usr/bin/xattr", args: ["-cr", tmpPath])
        // Verify it actually runs before swapping into place.
        guard let probed = await versionOf(path: tmpPath), !probed.isEmpty else {
            try? fileManager.removeItem(atPath: tmpPath)
            throw BinaryError.downloadFailed("Downloaded binary failed verification.")
        }
        let dest = supportBin("yt-dlp")
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: dest).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: dest) { try fileManager.removeItem(atPath: dest) }
        try fileManager.moveItem(atPath: tmpPath, toPath: dest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
        invalidateVersionCache()
        _ = locate()
        return await versionOf(path: dest) ?? probed
    }

    // MARK: - Helpers

    public enum BinaryError: LocalizedError {
        case missingYtDlp
        case downloadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingYtDlp:
                return "yt-dlp not found and couldn't be downloaded. Check your connection and press Download in Settings."
            case .downloadFailed(let m): return "Download failed: \(m)"
            }
        }
    }

    private func bundledCandidates(name: String) -> [String] {
        guard let res = Bundle.main.resourceURL else { return [] }
        return [res.appendingPathComponent("bin/\(name)").path]
    }

    private func supportBin(_ name: String) -> String {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash/bin", isDirectory: true).path
        return (base as NSString).appendingPathComponent(name)
    }

    private func firstExecutable(candidates: [String]) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func which(_ name: String) -> String? {
        if whichCache.keys.contains(name) { return whichCache[name] ?? nil }
        let found: String? = {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            p.arguments = [name]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let s, !s.isEmpty, fileManager.isExecutableFile(atPath: s) { return s }
            } catch { /* ignore */ }
            return nil
        }()
        whichCache[name] = found
        return found
    }

    private func versionOf(path: String) async -> String? {
        await runCapture(path, args: ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runCapture(_ exe: String, args: [String]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: String(data: data, encoding: .utf8))
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
