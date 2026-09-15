import Foundation
import os
import CryptoKit

/// Filename-safe content hash (artwork cache keys).
enum SHA256Hex {
    nonisolated static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Thin `Process` wrapper around `yt-dlp` + `ffmpeg` tagging.
/// `yt-dlp --dump-json` is the source of truth — formats are never hardcoded
/// except for our curated audio/video presets.
///
/// Reliability v1.1:
/// - Pipe-drain fix: stdout/stderr are consumed *while* the child runs.
///   Reading only after `waitUntilExit()` deadlocks once output exceeds the
///   64KB pipe buffer — a single-video `--dump-json` is ~540KB, which is why
///   fetches looked "stuck" forever with no error.
/// - Per-attempt timeouts + explicit probe cancellation (Cancel button).
/// - Single videos skip `--flat-playlist` entirely (`--flat-playlist` is a
///   no-op for singles and returns the same 540KB dump — the old code paid
///   for 3 full extractions per fetch).
/// - Player-client fallback chains + cookies/PO-token support via
///   `YouTubeAuth`. First success wins, even format-gated (metadata intact).
public actor YTDLPService: Sendable {
    /// Legacy default chain, kept for API compatibility.
    public static let playerClients = "android,ios,tv"

    /// Per-probe-attempt budget. First attempt gets the full budget,
    /// fallback chains get a shorter one so total fetch stays < ~70s.
    public static let probeTimeoutFirst: TimeInterval = 30
    public static let probeTimeoutFallback: TimeInterval = 20

    /// First-output watchdog for downloads: kill a yt-dlp run that prints
    /// nothing (no progress, no postprocessor lines) within this long after
    /// spawn, so a hung extraction fails fast into client fallback instead
    /// of sitting on "Preparing…" forever. Extraction normally starts in
    /// 5–15s; 30s is generous without letting a SABR-gated chain burn minutes.
    static let downloadFirstOutputTimeout: TimeInterval = 30

    /// Serializes download *extraction*: concurrent player-API extractions
    /// from one IP throttle each other (measured far slower than serial),
    /// while byte transfer parallelizes fine. Held only until first progress
    /// (or attempt end), so downloads overlap once flowing.
    nonisolated static let extractionGate = AsyncSemaphore(limit: 1)

    private let binaries: BinaryManager
    private let probes = ProbeRegistry()

    /// Active downloads for cancellation. Process is not Sendable;
    /// box it so the actor can hold it under Swift 6.
    private var active: [UUID: ProcessBox] = [:]

    /// Exact output paths from successful runs (`--print after_move:filepath`),
    /// keyed by job. The progress stream can't carry a result, so the store
    /// picks these up after the stream finishes — no directory scans.
    private var finishedPaths: [UUID: URL] = [:]

    /// Takes (and clears) the exact output path for a finished job, if any.
    public func takeFinishedPath(for id: UUID) -> URL? {
        defer { finishedPaths.removeValue(forKey: id) }
        return finishedPaths[id]
    }

    private nonisolated static let log = Logger(
        subsystem: "StitchProductions.BeatStash", category: "probes")

    /// Session probe cache: Fetch-info and Download share results so the same
    /// URL is never probed twice within the TTL. `raw` is the exact dump line
    /// (singles only) for `--load-info-json`, skipping re-extraction at download.
    static let probeCacheTTL: TimeInterval = 600
    private var probeCache: [String: (result: ProbeResult, raw: String?, at: Date)] = [:]

    /// Drops cached probes for `url` (call after a failed download retry, etc.).
    public func dropProbeCache(for url: String) {
        probeCache.removeValue(forKey: Self.probeCacheKey(url))
    }

    private static func probeCacheKey(_ url: String) -> String {
        normalizedProbeKey(url.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Normalizes probe cache keys so volatile share params don't bust the
    /// cache: same video/playlist pasted with `si`, `feature`, `pp`, `pp`,
    /// `app`, or reordered query items hits the same entry instead of paying
    /// for another full flat probe. Only `v`/`list`/`index` identify the
    /// content (plus the youtu.be path id); everything else is dropped.
    /// Non-YouTube URLs pass through untouched. Pure (tested).
    nonisolated static func normalizedProbeKey(_ url: String) -> String {
        guard let comps = URLComponents(string: url),
              let host = comps.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be")
        else { return url }
        if host.contains("youtu.be") {
            let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? url : "youtu.be:\(id.lowercased())"
        }
        let keep = Set(["v", "list", "index"])
        let items = (comps.queryItems ?? []).filter { keep.contains($0.name.lowercased()) }
            .sorted { $0.name < $1.name }
        guard !items.isEmpty else { return url }
        return "youtube:" + items.map { "\($0.name.lowercased())=\($0.value ?? "")" }.joined(separator: "&")
    }

    private func cacheProbe(key: String, result: ProbeResult, raw: String? = nil) {
        if probeCache.count > 64 { probeCache.removeAll() }
        probeCache[key] = (result, raw, Date())
    }

    // MARK: - Instant tier (oEmbed) + persistent probe cache

    /// oEmbed endpoint for a page URL. Pure (testable): all smarts are in the caller.
    /// Returns nil for non-URL input so garbage never becomes a request.
    nonisolated static func oEmbedURL(for pageURL: String) -> URL? {
        guard let page = URL(string: pageURL), page.scheme?.hasPrefix("http") == true else {
            return nil
        }
        var c = URLComponents(string: "https://www.youtube.com/oembed")
        c?.queryItems = [
            URLQueryItem(name: "url", value: page.absoluteString),
            URLQueryItem(name: "format", value: "json"),
        ]
        return c?.url
    }

    /// One tiny request (~0.15s): title/author/thumbnail, no duration or date.
    /// Throws on non-200 (age-gated/private/deleted) and offline — callers
    /// treat any failure as "fall through to the full probe".
    public func fetchOEmbed(url: String) async throws -> OEmbedVideo {
        guard let endpoint = Self.oEmbedURL(for: url) else {
            throw ServiceError.parseFailed("bad URL")
        }
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: endpoint, timeoutInterval: 10))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ServiceError.parseFailed("oEmbed status \(code)")
        }
        return try await MainActor.run {
            try JSONDecoder().decode(OEmbedVideo.self, from: data)
        }
    }

    /// On-disk probe results (7-day TTL, capped). Repeat pastes — even across
    /// launches — resolve instantly with full data, no network at all.
    static let diskCacheTTL: TimeInterval = 7 * 24 * 3600
    static let diskCacheCap = 500
    private struct DiskProbeEntry: Codable {
        var at: Date
        var result: ProbeResult
    }
    private var diskCache: [String: DiskProbeEntry]?

    /// Test seam: redirect the cache file (headless + Xcode tests).
    @MainActor static var diskCacheFileOverride: URL?
    @MainActor private static func diskCacheFile() -> URL {
        diskCacheFileOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash/probe-cache.json", isDirectory: false)
    }

    /// Reads + prunes the disk cache. MainActor: the Codable conformance lives there.
    @MainActor private static func readDiskCacheFile() -> [String: DiskProbeEntry] {
        guard let data = try? Data(contentsOf: diskCacheFile()) else { return [:] }
        guard var cache = try? JSONDecoder().decode([String: DiskProbeEntry].self, from: data) else { return [:] }
        cache = cache.filter { Date().timeIntervalSince($0.value.at) < diskCacheTTL }
        return cache
    }

    /// Prunes (TTL + cap) and persists. MainActor: Encodable lives there.
    @MainActor private static func writeDiskCacheFile(_ cache: [String: DiskProbeEntry]) {
        var pruned = cache.filter { Date().timeIntervalSince($0.value.at) < diskCacheTTL }
        if pruned.count > diskCacheCap {
            let newest = pruned.sorted { $0.value.at > $1.value.at }.prefix(diskCacheCap)
            pruned = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        try? FileManager.default.createDirectory(
            at: diskCacheFile().deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pruned) {
            try? data.write(to: diskCacheFile(), options: .atomic)
        }
    }

    /// Full-data hit from a previous fetch, or nil (miss/expired).
    /// Self-healing: playlist entries cached before `thumbnails[]` support
    /// carry no artwork at all — treat those as a miss so one fresh flat
    /// probe repopulates covers (then re-caches with art).
    public func diskCachedProbe(for url: String) async -> ProbeResult? {
        if diskCache == nil {
            diskCache = await Self.readDiskCacheFile()
        }
        // Normalized key first; raw trimmed URL as back-compat for entries
        // cached before key normalization (they age out via TTL/cap).
        let keys = [Self.probeCacheKey(url),
                    url.trimmingCharacters(in: .whitespacesAndNewlines)]
        for key in keys {
            guard let e = diskCache?[key],
                  Date().timeIntervalSince(e.at) < Self.diskCacheTTL else { continue }
            if case .playlist(_, let entries) = e.result, !entries.isEmpty,
               entries.allSatisfy({ $0.thumbnail == nil && ($0.thumbnails?.isEmpty ?? true) }) {
                return nil
            }
            return e.result
        }
        return nil
    }

    /// Warms the session cache and persists to disk. Callers are async already.
    private func cacheProbePersisting(key: String, result: ProbeResult, raw: String? = nil) async {
        cacheProbe(key: key, result: result, raw: raw)
        if diskCache == nil {
            diskCache = await Self.readDiskCacheFile()
        }
        diskCache?[key] = DiskProbeEntry(at: Date(), result: result)
        await Self.writeDiskCacheFile(diskCache ?? [:])
    }

    public init(binaries: BinaryManager = .shared) {
        self.binaries = binaries
    }

    // MARK: - Backend protocol surface

    public func fetchInfo(url: String) async throws -> ProbeResult {
        try await fetchInfo(url: url, auth: YouTubeAuth.load())
    }

    public func fetchInfo(url: String, auth: YouTubeAuth) async throws -> ProbeResult {
        guard await binaries.ytDlpPath != nil else { throw ServiceError.missingBinary }
        try Task.checkCancellation()
        let key = Self.probeCacheKey(url)
        let start = Date()
        if let hit = probeCache[key], Date().timeIntervalSince(hit.at) < Self.probeCacheTTL {
            Self.log.debug("probe cache hit: \(key, privacy: .public)")
            return hit.result
        }
        let chains = auth.clientChains()

        if Self.isListURL(url) {
            // Playlist path: cheap flat probe first (small for real playlists).
            var lastError: Error?
            for (i, chain) in chains.enumerated() {
                try Task.checkCancellation()
                do {
                    if let entries = try await flatPlaylist(
                        url: url, auth: auth, chain: chain,
                        timeout: i == 0 ? Self.probeTimeoutFirst : Self.probeTimeoutFallback
                    ), !entries.isEmpty {
                        // Playlist title rides along in flat entries — the extra
                        // `--print` spawn runs only when it's absent.
                        var title = entries.lazy.compactMap(\.playlistTitle).first
                        if title == nil {
                            title = await playlistTitle(url: url, auth: auth, chain: chain)
                        }
                        let result = ProbeResult.playlist(title: title, entries: entries)
                        await self.cacheProbePersisting(key: key, result: result)
                        Self.log.info("probe playlist: \(entries.count, privacy: .public) entries, chain \(i, privacy: .public), \(String(format: "%.1f", Date().timeIntervalSince(start)), privacy: .public)s: \(key, privacy: .public)")
                        return result
                    }
                    // List URL that resolved to a single video → fall through.
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    if !Self.isRetryableProbeError(error) { throw error }
                }
            }
            // Fall through to single-video dump (handles `watch?v=x&list=y`).
            if Task.isCancelled { throw CancellationError() }
            if let err = lastError, chains.count == 1 { throw err }
        }

        // Single-video path (also the common case): ONE full dump, chain fallback.
        var lastError: Error = ServiceError.parseFailed("empty response")
        for (i, chain) in chains.enumerated() {
            try Task.checkCancellation()
            do {
                let found = try await dumpSingle(
                    url: url, auth: auth, chain: chain,
                    timeout: i == 0 ? Self.probeTimeoutFirst : Self.probeTimeoutFallback
                )
                let result = ProbeResult.single(found.media)
                await self.cacheProbePersisting(key: key, result: result, raw: found.raw)
                Self.log.info("probe single: chain \(i, privacy: .public), \(String(format: "%.1f", Date().timeIntervalSince(start)), privacy: .public)s: \(key, privacy: .public)")
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if !Self.isRetryableProbeError(error) { throw error }
            }
        }
        throw lastError
    }

    /// Cancels all in-flight probes (Fetch → Cancel button).
    public func cancelProbes() {
        probes.cancelAll()
    }

    // MARK: - Probe helpers

    public nonisolated static func isListURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("list=") || lower.contains("/playlist")
    }

    /// Search-retry policy: bot-wall and network classes clear by themselves;
    /// everything else fails the track immediately. Pure (tested).
    nonisolated static func isSearchRetryable(_ error: Error) -> Bool {
        guard let e = error as? ServiceError else { return false }
        switch e {
        case .botCheck, .networkError, .probeTimeout:
            return true
        default:
            return false
        }
    }

    /// YouTube search for import matching: flat `ytsearchN:` results with
    /// id/title/duration/uploader (no formats, no player dance beyond the
    /// standard hardening). Serial callers only — search throttles like
    /// extractions (measured 3-parallel slower than serial).
    ///
    /// Bot-wall (403) and network failures retry with backoff (5s, 15s);
    /// anything else throws immediately. Callers add inter-search pacing.
    public func searchYouTube(query: String, limit: Int = 5) async throws -> [PlaylistEntry] {
        guard let ytDlp = await binaries.ytDlpPath else { throw ServiceError.missingBinary }
        try Task.checkCancellation()
        let args = YouTubeAuth.networkArgs
            + ["--flat-playlist", "--dump-json", "--no-warnings",
               "ytsearch\(max(1, min(limit, 10))):\(query)"]
        var lastError: Error = ServiceError.downloadFailed("search failed")
        for attempt in 0...2 {
            if attempt > 0 {
                try Task.checkCancellation()
                Self.log.info("search retry \(attempt, privacy: .public)/2 after backoff: \(query.prefix(40), privacy: .public)")
                try await Task.sleep(nanoseconds: UInt64([5, 15][attempt - 1]) * 1_000_000_000)
            }
            do {
                let out = try await runCapture(exe: ytDlp, args: args, timeout: 45)
                guard out.exitCode == 0 else { throw Self.classifyProbeError(stderr: out.stderr) }
                return await Self.parseFlatEntries(from: out.stdout) ?? []
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if Self.isSearchRetryable(error), attempt < 2 { continue }
                throw error
            }
        }
        throw lastError
    }

    /// Returns entries for playlists, `nil` for single videos.
    private func flatPlaylist(
        url: String, auth: YouTubeAuth, chain: [String], timeout: TimeInterval
    ) async throws -> [PlaylistEntry]? {
        guard let ytDlp = await binaries.ytDlpPath else { throw ServiceError.missingBinary }
        let t0 = Date()
        defer {
            Self.log.debug("flat probe (\(chain.joined(separator: ","), privacy: .public)): \(String(format: "%.1f", Date().timeIntervalSince(t0)), privacy: .public)s")
        }
        let args = Self.probeBaseArgs(auth: auth, chain: chain)
            + ["--flat-playlist", "--dump-json", "--no-warnings", url]
        let out: CapturedOutput
        do {
            out = try await runCapture(exe: ytDlp, args: args, timeout: timeout)
        } catch let e as ServiceError {
            throw e
        }
        guard out.exitCode == 0 else { throw Self.classifyProbeError(stderr: out.stderr) }
        return await Self.parseFlatEntries(from: out.stdout)
    }

    /// Line-delimited flat JSON → indexed entries, or `nil` for singles.
    /// MainActor: the `PlaylistEntry` Decodable conformance lives there.
    @MainActor static func parseFlatEntries(from stdout: String) -> [PlaylistEntry]? {
        let lines = stdout.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        let decoder = JSONDecoder()
        var entries: [PlaylistEntry] = []
        for line in lines {
            guard let data = line.data(using: .utf8) else { continue }
            if let e = try? decoder.decode(PlaylistEntry.self, from: data) {
                entries.append(e)
            }
        }
        // Single-vs-list split: real flat entries always carry playlist_index;
        // a single-video full dump (or an auto-mix of url redirects) decoded
        // by accident has none. Verified live: channel-uploads flat entries
        // have playlist_index; RD-mix url redirects do not.
        let indexed = entries.filter { $0.playlistIndex != nil }
        guard !indexed.isEmpty else { return nil }
        entries = indexed
        for i in entries.indices where entries[i].playlistIndex == nil {
            entries[i] = PlaylistEntry(
                id: entries[i].id, title: entries[i].title, url: entries[i].url,
                duration: entries[i].duration, thumbnail: entries[i].thumbnail,
                thumbnails: entries[i].thumbnails,
                uploader: entries[i].uploader, playlistIndex: i + 1
            )
        }
        return entries
    }

    private func playlistTitle(url: String, auth: YouTubeAuth, chain: [String]) async -> String? {
        guard let ytDlp = await binaries.ytDlpPath else { return nil }
        let args = Self.probeBaseArgs(auth: auth, chain: chain)
            + ["--flat-playlist", "--print", "%(playlist_title)s",
               "--no-warnings", "--playlist-end", "1", url]
        guard let out = try? await runCapture(exe: ytDlp, args: args, timeout: 20),
              out.exitCode == 0
        else { return nil }
        let t = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && t != "NA" { return t }
        return nil
    }

    private func dumpSingle(
        url: String, auth: YouTubeAuth, chain: [String], timeout: TimeInterval
    ) async throws -> (media: MediaInfo, raw: String) {
        guard let ytDlp = await binaries.ytDlpPath else { throw ServiceError.missingBinary }
        let t0 = Date()
        defer {
            Self.log.debug("dump probe (\(chain.joined(separator: ","), privacy: .public)): \(String(format: "%.1f", Date().timeIntervalSince(t0)), privacy: .public)s")
        }
        let args = Self.probeBaseArgs(auth: auth, chain: chain)
            + ["--dump-json", "--no-playlist", "--no-warnings", url]
        let out: CapturedOutput
        do {
            out = try await runCapture(exe: ytDlp, args: args, timeout: timeout)
        } catch let e as ServiceError {
            throw e
        }
        guard out.exitCode == 0 else { throw Self.classifyProbeError(stderr: out.stderr) }
        // yt-dlp may emit warnings above the JSON on stdout; scan for the object.
        if let found = await Self.decodeMediaWithRaw(from: out.stdout) { return found }
        throw Self.classifyProbeError(stderr: out.stderr, fallback: ServiceError.parseFailed(
            out.stderr.isEmpty ? "empty response from yt-dlp" : String(out.stderr.suffix(600))
        ))
    }

    /// Tolerates leading non-JSON lines: decodes the first line that parses.
    /// MainActor: `MediaInfo`'s Codable conformance lives there with the model.
    @MainActor static func decodeMedia(from stdout: String) -> MediaInfo? {
        decodeMediaWithRaw(from: stdout)?.media
    }

    /// Decode plus the exact JSON line that parsed (for `--load-info-json`,
    /// which needs pure JSON — warning lines would choke it).
    @MainActor static func decodeMediaWithRaw(from stdout: String) -> (media: MediaInfo, raw: String)? {
        let decoder = JSONDecoder()
        // Most common: single JSON object (possibly multi-line? no — one line).
        for line in stdout.components(separatedBy: .newlines).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{") else { continue }
            if let data = t.data(using: .utf8),
               let media = try? decoder.decode(MediaInfo.self, from: data) {
                return (media, t)
            }
        }
        // Fallback: whole blob (handles pretty-printed JSON).
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let media = try? decoder.decode(MediaInfo.self, from: data) {
            return (media, trimmed)
        }
        return nil
    }

    // MARK: - Error classification

    /// Hard per-client failures worth retrying on the next chain.
    /// Auth-gated results that will fail identically everywhere are thrown immediately.
    nonisolated static func isRetryableProbeError(_ error: Error) -> Bool {
        guard let e = error as? ServiceError else { return false } // unknown → retry once per chain
        switch e {
        case .probeTimeout, .clientFailed, .reloadRequired, .formatGated, .networkError, .downloadFailed:
            return true
        case .botCheck, .loginRequired, .videoUnavailable, .parseFailed, .missingBinary, .outputNotFound:
            return true // chains differ in trust; a login-gated client may still extract anonymously on another
        case .thumbnailUnsupported:
            return false // deterministic container limitation (probes never
                // embed thumbnails, so this is defense-only): no chain can fix it
        }
    }

    nonisolated static func classifyProbeError(stderr: String, fallback: ServiceError? = nil) -> ServiceError {
        let lower = stderr.lowercased()
        let tail = String(stderr.suffix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = tail.isEmpty ? stderr : tail
        if lower.contains("sign in to confirm you") || lower.contains("not a bot") {
            return .botCheck(msg)
        }
        // Search/API-surface throttling presents as API-page 403s.
        if lower.contains("unable to download api page")
            && (lower.contains("403") || lower.contains("forbidden")) {
            return .botCheck(msg)
        }
        if lower.contains("login required") || lower.contains("log in") || lower.contains("private video") {
            return .loginRequired(msg)
        }
        if lower.contains("page needs to be reloaded") {
            return .reloadRequired(msg)
        }
        // Deterministic container limitation, not a client problem: raised by
        // EmbedThumbnailPP after the expensive work, on every chain alike.
        if lower.contains("supported filetypes for thumbnail embedding") {
            return .thumbnailUnsupported(msg)
        }
        if lower.contains("requested format is not available") {
            return .formatGated(msg)
        }
        if lower.contains("video unavailable") || lower.contains("has been deleted")
            || lower.contains("has been removed") || lower.contains("private") {
            return .videoUnavailable(msg)
        }
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("temporary failure")
            || lower.contains("network is unreachable") || lower.contains("connection reset") {
            return .networkError(msg)
        }
        if let fb = fallback { return fb }
        return .downloadFailed(msg.isEmpty ? "yt-dlp failed with no message" : msg)
    }

    /// Download-time chain policy: transient rejections may pass on the next
    /// client; auth-gated failures fail identically everywhere. Pure (tested).
    nonisolated static func shouldRetryDownloadChain(error: Error, attemptsLeft: Int) -> Bool {
        guard attemptsLeft > 0 else { return false }
        guard let e = error as? ServiceError else { return true } // unknown → one more chain
        switch e {
        case .reloadRequired, .networkError, .formatGated, .botCheck,
             .probeTimeout, .clientFailed, .downloadFailed:
            return true
        case .loginRequired, .videoUnavailable, .parseFailed, .missingBinary, .outputNotFound,
             .thumbnailUnsupported:
            return false
        }
    }

    /// Store-level auto-requeue policy: only failures that clear by themselves
    /// (reloaded player session, healed network) earn silent retries, capped
    /// so a hard failure still surfaces. Pure (tested).
    nonisolated static func shouldAutoRequeue(error: Error, attemptsUsed: Int) -> Bool {
        guard attemptsUsed < 2 else { return false }
        guard let e = error as? ServiceError else { return false }
        switch e {
        case .reloadRequired, .networkError:
            return true
        default:
            return false
        }
    }

    // MARK: - Download

    public struct ProgressUpdate: Sendable {
        public var fraction: Double // 0...1
        public var speed: String?
        public var eta: String?
        public var rawLine: String?
        /// Human-readable phase for non-download output
        /// ("Converting audio…", "Preparing… trying option 2/4…"). Nil during bytes.
        public var phase: String? = nil
    }

    /// Downloads one job's bytes. Streams progress (including postprocessor
    /// phase labels); throws on failure. Tagging is the caller's job, so the
    /// queue slot can be freed before the ffmpeg post-pass.
    /// - Parameters:
    ///   - job: format/tags snapshot at enqueue time.
    ///   - directory: destination folder (created if needed).
    /// - Returns: final file URL.
    public func download(
        job: DownloadJob,
        to directory: URL
    ) -> AsyncThrowingStream<ProgressUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    _ = try await self.runDownload(job: job, to: directory) { update in
                        continuation.yield(update)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Usable stream URLs in a dump. SABR-gated dumps omit them — those must
    /// re-extract at download time instead of reusing the cached dump.
    /// Pure (testable): only touches the passed value.
    nonisolated static func usableFormatURLs(in media: MediaInfo) -> [String] {
        (media.formats ?? []).compactMap(\.url).filter { $0.hasPrefix("https://") }
    }

    /// Stages a `--load-info-json` file for this job when the session probe
    /// left a fresh, usable dump: single-video jobs only, entry younger than
    /// the session TTL (far inside stream-URL expiry), with real stream URLs.
    /// Returns the temp path, or nil to extract normally. Caller deletes it.
    private func prepareLoadInfoFile(job: DownloadJob) -> String? {
        guard job.playlistTitle == nil,
              let entry = probeCache[Self.probeCacheKey(job.url)],
              let raw = entry.raw,
              Date().timeIntervalSince(entry.at) < Self.probeCacheTTL,
              case .single(let media) = entry.result,
              !Self.usableFormatURLs(in: media).isEmpty
        else { return nil }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("beatstash-info-\(job.id.uuidString).json")
        do {
            try raw.write(to: dest, atomically: true, encoding: .utf8)
            return dest.path
        } catch {
            return nil
        }
    }

    /// Download with client fallback: transient rejections (stale player
    /// session, throttled/gated formats) retry on the next chain while
    /// auth-gated failures fail fast. Retries resume `.part` files through
    /// the shared -P/-o template instead of restarting.
    private func runDownload(
        job: DownloadJob,
        to directory: URL,
        onProgress: @Sendable @escaping (ProgressUpdate) -> Void
    ) async throws -> URL {
        guard await binaries.ytDlpPath != nil else { throw ServiceError.missingBinary }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let auth = YouTubeAuth.load()
        let chains = auth.clientChains()
        let start = Date()
        var lastError: Error = ServiceError.downloadFailed("yt-dlp failed with no message")
        for (i, chain) in chains.enumerated() {
            try Task.checkCancellation()
            // Plain-language phase: no client jargon, with the previous
            // failure's reason so the row never looks frozen and the user
            // can see *why* we're trying another option. The store appends
            // a live elapsed ticker on top.
            onProgress(ProgressUpdate(
                fraction: 0, speed: nil, eta: nil, rawLine: nil,
                phase: Self.preparingPhase(
                    attempt: i + 1, total: chains.count, lastError: i == 0 ? nil : lastError,
                    elapsed: Date().timeIntervalSince(start))))
            do {
                // Fresh cached dump only on the first attempt; retries
                // re-extract (the dump's URLs may be exactly what's stale).
                let url = try await runDownloadAttempt(
                    job: job, to: directory, auth: auth, chain: chain,
                    useLoadInfo: i == 0, onProgress: onProgress)
                finishedPaths[job.id] = url
                return url
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if Self.shouldRetryDownloadChain(error: error, attemptsLeft: chains.count - 1 - i) {
                    Self.log.info("download chain \(i, privacy: .public) failed, trying next: \(job.url, privacy: .public)")
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    /// One-line plain reason for a chain failure, for preparing-phase labels.
    /// No client names, no yt-dlp stderr — user-readable cause only.
    /// Pure (tested).
    nonisolated static func shortReason(for error: Error) -> String {
        guard let e = error as? ServiceError else { return "didn't respond" }
        switch e {
        case .formatGated: return "had no audio formats"
        case .reloadRequired: return "rejected the request"
        case .botCheck: return "asked for a sign-in check"
        case .loginRequired: return "needs a YouTube login"
        case .videoUnavailable: return "is unavailable"
        case .networkError: return "hit a network error"
        case .probeTimeout: return "timed out"
        case .clientFailed(let m):
            let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "didn't respond" : t
        case .downloadFailed(let m):
            let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return "didn't respond" }
            return String(t.prefix(80))
        case .parseFailed: return "couldn't be read"
        case .missingBinary: return "yt-dlp is missing"
        case .outputNotFound: return "produced no file"
        case .thumbnailUnsupported: return "can't carry cover art"
        }
    }

    /// Plain-language preparing label. Single-chain downloads stay a bare
    /// "Preparing…"; multi-chain runs name the option and carry the previous
    /// failure's reason. Elapsed ticks while the row looks otherwise frozen.
    /// Pure (tested).
    nonisolated static func preparingPhase(
        attempt: Int, total: Int, lastError: Error?, elapsed: TimeInterval
    ) -> String {
        var s: String
        if total <= 1 || attempt <= 1, lastError == nil {
            s = "Preparing…"
        } else if let lastError {
            s = "Preparing… trying option \(attempt)/\(total) · option \(attempt - 1) \(shortReason(for: lastError))"
        } else {
            s = "Preparing… trying option \(attempt)/\(total)"
        }
        let secs = Int(elapsed)
        if secs >= 2 { s += " · \(secs)s" }
        return s
    }

    /// Strips a trailing " · Ns" elapsed suffix so the store's ticker can
    /// re-stamp it every second without stacking suffixes. Pure (tested).
    nonisolated static func strippingElapsedSuffix(_ phase: String) -> String {
        var s = phase
        while let range = s.range(of: #" · \d+s$"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s
    }

    /// One process run for a single client chain (isolated so `active`
    /// bookkeeping is safe).
    private func runDownloadAttempt(
        job: DownloadJob,
        to directory: URL,
        auth: YouTubeAuth,
        chain: [String],
        useLoadInfo: Bool,
        onProgress: @Sendable @escaping (ProgressUpdate) -> Void
    ) async throws -> URL {
        guard let ytDlp = await binaries.ytDlpPath else { throw ServiceError.missingBinary }
        var args = await buildArguments(job: job, directory: directory, auth: auth, chain: chain)
        // Skip re-extraction when the session probe left a fresh, usable dump:
        // no player-API roundtrips at download start (and no throttle pileup
        // across concurrent jobs). Falls back silently when ineligible.
        let loadInfoPath = useLoadInfo ? prepareLoadInfoFile(job: job) : nil
        if let loadInfoPath {
            args += ["--load-info-json", loadInfoPath]
        }
        defer {
            if let loadInfoPath {
                try? FileManager.default.removeItem(atPath: loadInfoPath)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = args
        // Unbuffered progress lines.
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        active[job.id] = ProcessBox(process)
        let box = active[job.id]!

        // Serialize extraction: concurrent player-API extractions throttle
        // each other. Released on first progress (bytes flowing → the slow
        // part is over) or attempt end, so downloads still overlap.
        await Self.extractionGate.acquire()
        let gateReleased = LockedFlag()
        let releaseExtractionOnce: @Sendable () -> Void = {
            if !gateReleased.value {
                gateReleased.set()
                Self.extractionGate.release()
            }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            // Read progress off-thread. `FinishGate` is Sendable and guarantees single resume.
            let gate = FinishGate(cont)
            let outHandle = outPipe.fileHandleForReading
            let jobID = job.id
            let clearActive: @Sendable () -> Void = { [weak self] in
                Task { await self?.clearActive(id: jobID) }
            }
            let lines = ProgressLineBuffer()
            let sawOutput = LockedFlag()
            let timedOut = LockedFlag()
            let finished = LockedFlag()
            let printedPath = PrintedPathBox()

            // First-output watchdog: a hung extraction prints nothing —
            // kill it into client fallback instead of Preparing… forever.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.downloadFirstOutputTimeout * 1_000_000_000))
                if !finished.value, !sawOutput.value, box.process.isRunning {
                    timedOut.set()
                    box.process.terminate()
                }
            }

            outHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                sawOutput.set()
                releaseExtractionOnce()
                for line in lines.append(text) {
                    if let p = Self.parsePrintedFilePath(line: line) {
                        printedPath.set(p)
                    }
                    if let p = Self.parseProgress(line: line) {
                        lines.setFraction(p.fraction)
                        onProgress(p)
                    } else if let phase = Self.phaseFor(line: line) {
                        onProgress(ProgressUpdate(
                            fraction: lines.fraction, speed: nil, eta: nil,
                            rawLine: line, phase: phase))
                    }
                }
            }

            process.terminationHandler = { proc in
                finished.set()
                outHandle.readabilityHandler = nil
                clearActive()
                releaseExtractionOnce()
                if timedOut.value {
                    gate.resume(throwing: ServiceError.probeTimeout(Self.downloadFirstOutputTimeout))
                } else if proc.terminationStatus == 0 {
                    if let p = printedPath.value,
                       FileManager.default.fileExists(atPath: p) {
                        gate.resume(returning: URL(fileURLWithPath: p))
                    } else if let file = Self.newestFile(in: directory, matching: job) {
                        gate.resume(returning: file)
                    } else if let file = Self.newestAudioFile(in: directory) {
                        gate.resume(returning: file)
                    } else {
                        gate.resume(throwing: ServiceError.outputNotFound)
                    }
                } else {
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // Classify so chain fallback + messages understand the failure;
                    // keep the exit code when yt-dlp said nothing at all.
                    let fallback: ServiceError? = msg.isEmpty
                        ? .downloadFailed("yt-dlp exited with code \(proc.terminationStatus)") : nil
                    gate.resume(throwing: Self.classifyProbeError(stderr: msg, fallback: fallback))
                }
            }

            do {
                try process.run()
            } catch {
                finished.set()
                releaseExtractionOnce()
                gate.resume(throwing: error)
            }
        }
    }

    public func cancel(id: UUID) {
        active[id]?.process.terminate()
        active.removeValue(forKey: id)
        finishedPaths.removeValue(forKey: id)
    }

    private func clearActive(id: UUID) {
        active.removeValue(forKey: id)
    }

    // MARK: - Argument builders (public for testing / preview)

    public func buildArguments(job: DownloadJob, directory: URL) async -> [String] {
        await buildArguments(job: job, directory: directory, auth: YouTubeAuth.load())
    }

    /// `--ffmpeg-location` for a resolved ffmpeg path (pure, testable).
    /// Directory form covers both ffmpeg and ffprobe. Empty when unknown —
    /// yt-dlp then falls back to PATH (today's behavior).
    nonisolated static func ffmpegLocationArgs(ffmpegPath: String?) -> [String] {
        guard let ffmpegPath, !ffmpegPath.isEmpty else { return [] }
        let dir = URL(fileURLWithPath: ffmpegPath).deletingLastPathComponent().path
        guard !dir.isEmpty else { return [] }
        return ["--ffmpeg-location", dir]
    }

    func buildArguments(job: DownloadJob, directory: URL, auth: YouTubeAuth, chain: [String]? = nil) async -> [String] {
        var args: [String] = [
            "--no-playlist",
            "--ignore-errors",
            "--no-overwrites",
            "--newline", "--progress",
            "--no-warnings",
            "--embed-metadata",
        ]
        args += YouTubeAuth.networkArgs
        args += auth.authArgs()
        // Point postprocessing at the resolved ffmpeg (bundled or custom).
        // Without this the child inherits the GUI app's minimal PATH and every
        // `-x` / thumbnail / merge step fails with "ffmpeg not found".
        args += Self.ffmpegLocationArgs(ffmpegPath: await binaries.ffmpegPath)
        // Download on the given chain (first = anonymous-first); cookies (if any)
        // ride along. PO-token plugin flags are appended when a runtime + plugins exist.
        if let chain = chain ?? auth.clientChains().first {
            args += YouTubeAuth.clientArgs(for: chain)
        }
        args += pluginArgs()
        // Ask yt-dlp to report its exact final path: resolves history +
        // Finder-reveal without scanning the destination directory (which
        // stalls on big batches and misattributes files under concurrency).
        // Parsed out of stdout in `runDownloadAttempt`; scans stay as fallback.
        args += ["--print", "after_move:filepath"]
        args += ["-P", directory.path]
        switch job.kind {
        case .audio:
            args += [
                "-x",
                "--audio-format", job.audioFormat.ytDlpValue,
                "--audio-quality", "0",
            ]
            // yt-dlp hard-fails the whole job when asked to embed a thumbnail
            // into a container that can't carry one (WAV) — after the full
            // download + transcode. Gate the flags per format instead so the
            // failure can never happen; our own tag pass likewise skips art
            // for WAV (spec-poor). Pure helper, tested.
            args += Self.thumbnailEmbedArgs(for: job.audioFormat)
            args += [
                "--add-metadata",
                "-o", "%(playlist_index)02d - %(title)s [%(id)s].%(ext)s",
            ]
        case .video:
            args += [
                "-f", "bv*[height<=\(job.videoQuality.maxHeight)]+ba/b",
                "--merge-output-format", "mp4",
                "--embed-thumbnail", "--convert-thumbnails", "jpg",
                "-o", "%(title)s [%(id)s].%(ext)s",
            ]
        }
        args.append(job.url)
        return args
    }

    /// Thumbnail-embed flags for an audio target. yt-dlp supports embedding
    /// into mp3, ogg/opus, flac, m4a/mp4-family — everything we offer except
    /// WAV, which fails the entire postprocess chain (`Supported filetypes
    /// for thumbnail embedding are: …`). Skipping the flags also skips the
    /// pointless thumbnail download + convert for WAV. Pure (tested).
    nonisolated static func thumbnailEmbedArgs(for format: AudioFormat) -> [String] {
        guard format != .wav else { return [] }
        return ["--embed-thumbnail", "--convert-thumbnails", "jpg"]
    }

    /// Shared probe prefix: hardening + auth + client + optional POT plugin.
    /// `--ignore-no-formats-error` guarantees the metadata-intact contract:
    /// a SABR/format-gated video succeeds on the first chain with its title
    /// etc. instead of burning every fallback chain. Probe-only — downloads
    /// must still fail loudly when no usable format exists.
    nonisolated static func probeBaseArgs(auth: YouTubeAuth, chain: [String]) -> [String] {
        var args = YouTubeAuth.networkArgs
        args += auth.authArgs()
        args += YouTubeAuth.clientArgs(for: chain)
        args += ["--ignore-no-formats-error"]
        return args
    }

    /// `--plugin-dirs` + `--js-runtimes` only when both exist on disk.
    /// Keeps stock installs working with zero extra dependencies.
    private func pluginArgs() -> [String] {
        var args: [String] = []
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let plugins = res.appendingPathComponent("plugins").path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: plugins, isDirectory: &isDir), isDir.boolValue {
                args += ["--plugin-dirs", plugins]
            }
        }
        if Self.jsRuntimeAvailable() {
            args += ["--js-runtimes", "node:deno"]
        }
        return args
    }

    /// Any JS runtime yt-dlp can use for challenges / PO-token generation.
    static func jsRuntimeAvailable() -> Bool {
        which("deno") != nil || which("node") != nil
    }

    static func jsRuntimeName() -> String? {
        if which("deno") != nil { return "deno" }
        if which("node") != nil { return "node" }
        return nil
    }

    private static func which(_ name: String) -> String? {
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
            if let s, !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        } catch { /* ignore */ }
        return nil
    }

    // MARK: - Tagging (ffmpeg post-pass)

    /// Output-side ffmpeg args for the tag rewrite: text metadata always,
    /// cover art when `artPath` is set (audio streams re-mapped, so a
    /// YouTube thumbnail embedded at download time is *replaced*, not doubled).
    /// WAV takes text only (cover support is spec-poor). Pure (tested).
    nonisolated static func tagOutputArgs(tags: TrackTags, format: AudioFormat, artPath: String?) -> [String] {
        var args: [String] = []
        if artPath != nil, format != .wav {
            args += ["-map", "0:a", "-map", "1", "-c", "copy",
                     "-disposition:v", "attached_pic"]
        }
        args += ["-metadata", "artist=\(tags.artist)"]
        args += ["-metadata", "title=\(tags.title)"]
        args += ["-metadata", "album=\(tags.album)"]
        if let n = tags.trackNumber { args += ["-metadata", "track=\(n)"] }
        if let y = tags.year, !y.isEmpty { args += ["-metadata", "date=\(y)"] }
        if let g = tags.genre, !g.isEmpty { args += ["-metadata", "genre=\(g)"] }
        if format == .mp3 {
            args += ["-id3v2_version", "3", "-write_id3v1", "1"]
        } else if format == .wav {
            args += ["-c", "copy", "-write_bext", "1"]
            return args
        }
        if artPath == nil || format == .wav {
            args += ["-c", "copy"]
        }
        return args
    }

    /// Overwrites metadata in place via temp file. Best-effort per format.
    /// WAV: only INFO + BWF chunks are writable — Finder/Music may ignore them (spec limit).
    /// With Spotify artwork: downloaded once, cached, and attached (replacing
    /// any YouTube thumbnail); failures fall back to text-only tagging.
    /// The temp file replaces the original only on a clean ffmpeg exit with
    /// non-empty output — a killed/timed-out pass keeps the yt-dlp output.
    public func applyTags(to file: URL, tags: TrackTags, format: AudioFormat, artworkURL: String? = nil) async throws {
        guard let ffmpeg = await binaries.ffmpegPath else { return } // no ffmpeg → keep untagged file
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.deletingPathExtension().lastPathComponent).tagged.\(file.pathExtension)")
        try? FileManager.default.removeItem(at: tmp) // stale temp from a killed pass
        var args = ["-y", "-i", file.path]
        var artPath: String?
        if let artworkURL, !artworkURL.isEmpty, format != .wav {
            artPath = await ensureArtwork(url: artworkURL)
            if let artPath { args += ["-i", artPath] }
        }
        args += Self.tagOutputArgs(tags: tags, format: format, artPath: artPath)
        args.append(tmp.path)
        do {
            let out = try await runCapture(exe: ffmpeg, args: args, timeout: 60)
            guard out.exitCode == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                return
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path),
              let size = attrs[.size] as? NSNumber, size.intValue > 0
        else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: tmp, to: file)
        }
    }

    /// Artwork cache cap (files; oldest mtime pruned on write).
    static let artworkCap = 500

    /// Downloads (if needed) and caches cover art. Returns the local path,
    /// or nil to fall back to text-only tagging. Images only, <10 MB.
    public func ensureArtwork(url: String) async -> String? {
        guard let remote = URL(string: url),
              remote.scheme?.hasPrefix("http") == true else { return nil }
        let digest = SHA256Hex.digest(remote.absoluteString)
        let dest = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash/artwork/\(digest).jpg", isDirectory: false)
        if FileManager.default.isReadableFile(atPath: dest.path) { return dest.path }
        do {
            var req = URLRequest(url: remote, timeoutInterval: 10)
            req.setValue("image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 1_024, data.count < 10_000_000,
                  let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
                  mime.hasPrefix("image/")
            else { return nil }
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
            pruneArtworkCache(dir: dest.deletingLastPathComponent())
            return dest.path
        } catch {
            return nil
        }
    }

    /// Drops oldest files past the cap. Best-effort, never throws.
    private func pruneArtworkCache(dir: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        guard items.count > Self.artworkCap else { return }
        let dated = items.map { url -> (URL, Date) in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return (url, d)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(items.count - Self.artworkCap) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Progress parse

    private static let percentRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)%"#)
    }()
    private static let speedRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"at\s+([^\s]+)"#)
    }()
    private static let etaRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"ETA\s+([^\s]+)"#)
    }()

    /// `[download]  42.3% of ~5.12MiB at 2.10MiB/s ETA 00:02`
    /// Internal for tests (output contract with the download runner).
    nonisolated static func parseProgress(line: String) -> ProgressUpdate? {
        guard line.contains("[download]") && line.contains("%") else { return nil }
        // Percent
        let range = NSRange(line.startIndex..., in: line)
        guard let m = percentRegex.firstMatch(in: line, range: range),
              let r = Range(m.range(at: 1), in: line),
              let pct = Double(line[r])
        else { return nil }
        var speed: String?
        var eta: String?
        if let sm = speedRegex.firstMatch(in: line, range: range),
           let sr = Range(sm.range(at: 1), in: line) {
            speed = String(line[sr])
        }
        if let em = etaRegex.firstMatch(in: line, range: range),
           let er = Range(em.range(at: 1), in: line) {
            eta = String(line[er])
        }
        return ProgressUpdate(fraction: min(max(pct / 100, 0), 1), speed: speed, eta: eta, rawLine: line)
    }

    /// Human-readable phase for yt-dlp's non-download output lines, so the
    /// queue never looks frozen during postprocessing (which emits no `%`).
    /// Pure (tested). Check specific tags before generic ones.
    nonisolated static func phaseFor(line: String) -> String? {
        // WAV transcodes are huge (~10MB/min) with no progress: say so.
        if line.contains("[ExtractAudio]"), line.lowercased().contains("wav") {
            return "Saving WAV… large file, may sit at 100% a while"
        }
        if line.contains("[ExtractAudio]") { return "Converting audio…" }
        if line.contains("[EmbedThumbnail]") { return "Embedding cover…" }
        if line.contains("[ThumbnailsConvert]") { return "Converting cover…" }
        if line.contains("[Metadata]") { return "Writing metadata…" }
        if line.contains("[Merger]") { return "Merging formats…" }
        if line.contains("[VideoConvertor]") { return "Converting video…" }
        if line.contains("[VideoRemuxer]") { return "Remuxing video…" }
        if line.contains("[download]") && line.contains("Destination:") {
            return "Starting download…"
        }
        return nil
    }

    /// Picks `--print after_move:filepath` lines out of progress output.
    /// The print is a bare absolute path, while every line yt-dlp itself
    /// emits is tagged (`[download] …`, `[info] …`) — so a leading `/`
    /// discriminates. Filenames routinely contain `[id]` and `%`, which must
    /// NOT be excluded. Pure (tested).
    nonisolated static func parsePrintedFilePath(line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), !t.contains("\t"), t.count > 2 else { return nil }
        return t
    }

    /// Splits a pipe chunk into complete lines, carrying a partial trailing
    /// line in `remainder` for the next chunk (pipe reads split UTF-8 lines
    /// arbitrarily). Pure (tested).
    nonisolated static func appendLines(buffer: String, chunk: String) -> (lines: [String], remainder: String) {
        let text = buffer + chunk
        var lines = text.components(separatedBy: .newlines)
        let remainder = lines.removeLast()
        return (lines, remainder)
    }

    // MARK: - Low-level run

    public enum ServiceError: LocalizedError, Equatable {
        case missingBinary
        case parseFailed(String)
        case downloadFailed(String)
        case outputNotFound
        case probeTimeout(TimeInterval)
        case botCheck(String)
        case loginRequired(String)
        case videoUnavailable(String)
        case reloadRequired(String)
        case formatGated(String)
        case networkError(String)
        case clientFailed(String)
        case thumbnailUnsupported(String)

        public var errorDescription: String? {
            switch self {
            case .missingBinary:
                return "yt-dlp not found. Let BeatStash download it on first launch."
            case .parseFailed(let m):
                return "Couldn't read video info (\(m)). The link may be private, deleted, or YouTube changed its format."
            case .downloadFailed(let m):
                return m
            case .outputNotFound:
                return "Download finished but no file was found."
            case .probeTimeout(let s):
                return "YouTube took longer than \(Int(s))s to respond. Check your connection, or press Update yt-dlp in Settings and retry."
            case .botCheck(let m):
                return "YouTube asked for a sign-in bot check. Add cookies in Settings → YouTube sign-in (throwaway account recommended), then retry. \(m)"
            case .loginRequired(let m):
                return "This video needs a YouTube login (private, members-only, or age-restricted). Add cookies in Settings → YouTube sign-in. \(m)"
            case .videoUnavailable(let m):
                return "YouTube says this video is unavailable (deleted, removed, or blocked). \(m)"
            case .reloadRequired(let m):
                return "YouTube rejected this client (\(m)). BeatStash already retries other clients — updating yt-dlp usually fixes this."
            case .formatGated(let m):
                return "YouTube withheld formats for this client (\(m)). BeatStash retries other clients automatically."
            case .networkError(let m):
                return "Network problem reaching YouTube (\(m)). Retry in a moment."
            case .clientFailed(let m):
                return "All YouTube clients failed (\(m)). Update yt-dlp and retry."
            case .thumbnailUnsupported(let m):
                return "This container can't carry cover art, so the cover step was refused (\(m)). The audio itself is fine — WAV carries text tags only; pick MP3, M4A, Opus, or FLAC for embedded covers."
            }
        }
    }

    struct CapturedOutput {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    /// Deadlock-free capture: both pipes are drained on background threads
    /// *while* the child runs, then `waitUntilExit` joins. A per-call
    /// `timeout` terminates stalled probes. Registered in `probes` so
    /// `cancelProbes()` can kill in-flight fetches (Cancel button).
    private func runCapture(exe: String, args: [String], timeout: TimeInterval) async throws -> CapturedOutput {
        let id = UUID()
        let probes = self.probes // captured on-actor; registry is internally locked
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CapturedOutput, Error>) in
            let gate = CaptureGate(cont)
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                probes.register(id: id, process: p)
                defer { probes.unregister(id: id) }

                do {
                    try p.run()
                } catch {
                    gate.resume(throwing: error)
                    return
                }

                // Timeout killer: terminate a stalled child; the wait below
                // then returns promptly and we report a timeout error.
                let timedOut = LockedFlag()
                let killer = DispatchWorkItem { [weak p] in
                    guard let p, p.isRunning else { return }
                    timedOut.set()
                    p.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                // Drain both pipes concurrently — never wait with a full buffer.
                let group = DispatchGroup()
                let outBox = DataBox()
                let errBox = DataBox()
                group.enter()
                DispatchQueue.global().async {
                    outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                p.waitUntilExit()
                group.wait()
                killer.cancel()

                if probes.wasCancelled(id: id) {
                    gate.resume(throwing: CancellationError())
                    return
                }
                let stdout = String(data: outBox.data, encoding: .utf8) ?? ""
                let stderr = String(data: errBox.data, encoding: .utf8) ?? ""
                if timedOut.value {
                    if p.terminationStatus == 0, !stdout.isEmpty {
                        gate.resume(returning: CapturedOutput(stdout: stdout, stderr: stderr, exitCode: 0))
                    } else {
                        gate.resume(throwing: ServiceError.probeTimeout(timeout))
                    }
                    return
                }
                gate.resume(returning: CapturedOutput(stdout: stdout, stderr: stderr, exitCode: p.terminationStatus))
            }
        }
    }

    private static func newestFile(in dir: URL, matching job: DownloadJob) -> URL? {
        let ext = job.kind == .audio ? job.audioFormat.fileExtension : "mp4"
        return newestFile(in: dir, matchingExtension: ext)
    }

    private static func newestAudioFile(in dir: URL) -> URL? {
        newestFile(in: dir, matchingExtension: nil)
    }

    /// Single directory scan: fetch modification dates once, then max().
    /// Avoids O(n log n) `resourceValues` syscalls inside a sort comparator.
    private static func newestFile(in dir: URL, matchingExtension ext: String?) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        var newest: URL?
        var newestDate = Date.distantPast
        for url in items {
            if let ext, url.pathExtension.lowercased() != ext { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date > newestDate {
                newestDate = date
                newest = url
            }
        }
        return newest
    }
}

/// `Process` is not `Sendable`; box it for actor storage.
/// `nonisolated(unsafe)` throughout this section: every type here is
/// lock-guarded (or immutable) by design and must be callable from GCD
/// blocks, while the project default isolation is MainActor.
final class ProcessBox: @unchecked Sendable {
    let process: Process
    nonisolated init(_ process: Process) { self.process = process }
}

/// Tracks in-flight probe processes so `cancelProbes()` can kill them.
/// Lock-guarded (not actor-isolated) because it is driven from GCD blocks.
final class ProbeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var processes: [UUID: Process] = [:]
    nonisolated(unsafe) private var cancelled: Set<UUID> = []
    nonisolated init() {}

    nonisolated func register(id: UUID, process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes[id] = process
    }

    nonisolated func unregister(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        processes.removeValue(forKey: id)
    }

    nonisolated func wasCancelled(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(id)
    }

    nonisolated func cancelAll() {
        lock.lock()
        let procs = Array(processes.values)
        for id in processes.keys { cancelled.insert(id) }
        lock.unlock()
        for p in procs {
            if p.isRunning { p.terminate() }
        }
        // Bounded memory: drop old cancellation marks.
        lock.lock()
        if cancelled.count > 64 { cancelled.removeAll() }
        lock.unlock()
    }
}

/// Single-resume gate for `CheckedContinuation` across concurrent handlers.
final class FinishGate: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var done = false
    private let cont: CheckedContinuation<URL, Error>

    nonisolated init(_ cont: CheckedContinuation<URL, Error>) { self.cont = cont }

    nonisolated func resume(returning value: URL) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        cont.resume(returning: value)
    }

    nonisolated func resume(throwing error: Error) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        cont.resume(throwing: error)
    }
}

/// Single-resume gate for capture continuations.
final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var done = false
    private let cont: CheckedContinuation<YTDLPService.CapturedOutput, Error>

    nonisolated init(_ cont: CheckedContinuation<YTDLPService.CapturedOutput, Error>) { self.cont = cont }

    nonisolated func resume(returning value: YTDLPService.CapturedOutput) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        cont.resume(returning: value)
    }

    nonisolated func resume(throwing error: Error) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        cont.resume(throwing: error)
    }
}

/// Plain byte buffer for cross-thread pipe draining.
final class DataBox: @unchecked Sendable {
    nonisolated(unsafe) var data = Data()
    nonisolated init() {}
}

/// Lock-guarded boolean flag.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var flag = false

    nonisolated init() {}

    nonisolated var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    nonisolated func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}

/// Minimal async semaphore (permits + FIFO waiter queue), for serializing
/// download extraction across concurrent jobs. Lock-guarded; `acquire`
/// suspends without blocking a thread.
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var permits: Int
    nonisolated(unsafe) private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated init(limit: Int) { permits = max(limit, 1) }

    func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if permits > 0 {
                permits -= 1
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    nonisolated func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            permits += 1
            lock.unlock()
            return
        }
        let next = waiters.removeFirst()
        lock.unlock()
        next.resume()
    }
}

/// Lock-guarded pipe line buffer: partial-line remainder plus the last seen
/// progress fraction (so phase-only updates keep the bar where it was).
final class ProgressLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var remainder = ""
    nonisolated(unsafe) private var lastFraction = 0.0

    nonisolated init() {}

    /// Appends a chunk, returning complete lines. Thread-safe.
    nonisolated func append(_ chunk: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let (lines, rest) = YTDLPService.appendLines(buffer: remainder, chunk: chunk)
        remainder = rest
        return lines
    }

    nonisolated var fraction: Double {
        lock.lock(); defer { lock.unlock() }
        return lastFraction
    }

    nonisolated func setFraction(_ f: Double) {
        lock.lock(); defer { lock.unlock() }
        lastFraction = f
    }
}

/// Lock-guarded holder for the `--print after_move:filepath` line: the last
/// bare-path line wins (single-file runs print exactly one).
final class PrintedPathBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var path: String?

    nonisolated init() {}

    nonisolated var value: String? {
        lock.lock(); defer { lock.unlock() }
        return path
    }

    nonisolated func set(_ p: String) {
        lock.lock(); defer { lock.unlock() }
        path = p
    }
}
