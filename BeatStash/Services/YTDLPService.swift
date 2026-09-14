import Foundation
import os

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

    private let binaries: BinaryManager
    private let probes = ProbeRegistry()

    /// Active downloads for cancellation. Process is not Sendable;
    /// box it so the actor can hold it under Swift 6.
    private var active: [UUID: ProcessBox] = [:]

    private nonisolated static let log = Logger(
        subsystem: "StitchProductions.BeatStash", category: "probes")

    /// Session probe cache: Fetch-info and Download share results so the same
    /// URL is never probed twice within the TTL.
    static let probeCacheTTL: TimeInterval = 600
    private var probeCache: [String: (result: ProbeResult, at: Date)] = [:]

    /// Drops cached probes for `url` (call after a failed download retry, etc.).
    public func dropProbeCache(for url: String) {
        probeCache.removeValue(forKey: Self.probeCacheKey(url))
    }

    private static func probeCacheKey(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cacheProbe(key: String, result: ProbeResult) {
        if probeCache.count > 64 { probeCache.removeAll() }
        probeCache[key] = (result, Date())
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
                        self.cacheProbe(key: key, result: result)
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
                let media = try await dumpSingle(
                    url: url, auth: auth, chain: chain,
                    timeout: i == 0 ? Self.probeTimeoutFirst : Self.probeTimeoutFallback
                )
                let result = ProbeResult.single(media)
                self.cacheProbe(key: key, result: result)
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

    public static func isListURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("list=") || lower.contains("/playlist")
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
        let lines = out.stdout.components(separatedBy: .newlines)
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
    ) async throws -> MediaInfo {
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
        if let media = Self.decodeMedia(from: out.stdout) { return media }
        throw Self.classifyProbeError(stderr: out.stderr, fallback: ServiceError.parseFailed(
            out.stderr.isEmpty ? "empty response from yt-dlp" : String(out.stderr.suffix(600))
        ))
    }

    /// Tolerates leading non-JSON lines: decodes the first line that parses.
    static func decodeMedia(from stdout: String) -> MediaInfo? {
        let decoder = JSONDecoder()
        // Most common: single JSON object (possibly multi-line? no — one line).
        for line in stdout.components(separatedBy: .newlines).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{") else { continue }
            if let data = t.data(using: .utf8),
               let media = try? decoder.decode(MediaInfo.self, from: data) {
                return media
            }
        }
        // Fallback: whole blob (handles pretty-printed JSON).
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let media = try? decoder.decode(MediaInfo.self, from: data) {
            return media
        }
        return nil
    }

    // MARK: - Error classification

    /// Hard per-client failures worth retrying on the next chain.
    /// Auth-gated results that will fail identically everywhere are thrown immediately.
    static func isRetryableProbeError(_ error: Error) -> Bool {
        guard let e = error as? ServiceError else { return false } // unknown → retry once per chain
        switch e {
        case .probeTimeout, .clientFailed, .reloadRequired, .formatGated, .networkError, .downloadFailed:
            return true
        case .botCheck, .loginRequired, .videoUnavailable, .parseFailed, .missingBinary, .outputNotFound:
            return true // chains differ in trust; a login-gated client may still extract anonymously on another
        }
    }

    static func classifyProbeError(stderr: String, fallback: ServiceError? = nil) -> ServiceError {
        let lower = stderr.lowercased()
        let tail = String(stderr.suffix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = tail.isEmpty ? stderr : tail
        if lower.contains("sign in to confirm you") || lower.contains("not a bot") {
            return .botCheck(msg)
        }
        if lower.contains("login required") || lower.contains("log in") || lower.contains("private video") {
            return .loginRequired(msg)
        }
        if lower.contains("page needs to be reloaded") {
            return .reloadRequired(msg)
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

    // MARK: - Download

    public struct ProgressUpdate: Sendable {
        public var fraction: Double // 0...1
        public var speed: String?
        public var eta: String?
        public var rawLine: String?
    }

    /// Downloads one job. Streams progress; throws on failure.
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
                    let file = try await self.runDownload(job: job, to: directory) { update in
                        continuation.yield(update)
                    }
                    // Tag pass (ffmpeg). Best-effort: don't fail DL if tagging fails,
                    // surface via error only if file missing.
                    if job.kind == .audio {
                        try? await self.applyTags(to: file, tags: job.tags, format: job.audioFormat)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Actual process run (isolated so `active` bookkeeping is safe).
    private func runDownload(
        job: DownloadJob,
        to directory: URL,
        onProgress: @Sendable @escaping (ProgressUpdate) -> Void
    ) async throws -> URL {
        guard let ytDlp = await binaries.ytDlpPath else { throw ServiceError.missingBinary }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let auth = YouTubeAuth.load()
        let args = buildArguments(job: job, directory: directory, auth: auth)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = args
        // Unbuffered progress lines.
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        active[job.id] = ProcessBox(process)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            // Read progress off-thread. `FinishGate` is Sendable and guarantees single resume.
            let gate = FinishGate(cont)
            let outHandle = outPipe.fileHandleForReading
            let jobID = job.id
            let clearActive: @Sendable () -> Void = { [weak self] in
                Task { await self?.clearActive(id: jobID) }
            }

            outHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.components(separatedBy: .newlines) {
                    if let p = Self.parseProgress(line: line) {
                        onProgress(p)
                    }
                }
            }

            process.terminationHandler = { proc in
                outHandle.readabilityHandler = nil
                clearActive()
                if proc.terminationStatus == 0 {
                    if let file = Self.newestFile(in: directory, matching: job) {
                        gate.resume(returning: file)
                    } else if let file = Self.newestAudioFile(in: directory) {
                        gate.resume(returning: file)
                    } else {
                        gate.resume(throwing: ServiceError.outputNotFound)
                    }
                } else {
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    gate.resume(throwing: ServiceError.downloadFailed(msg?.isEmpty == false ? msg! : "yt-dlp exited with code \(proc.terminationStatus)"))
                }
            }

            do {
                try process.run()
            } catch {
                gate.resume(throwing: error)
            }
        }
    }

    public func cancel(id: UUID) {
        active[id]?.process.terminate()
        active.removeValue(forKey: id)
    }

    private func clearActive(id: UUID) {
        active.removeValue(forKey: id)
    }

    // MARK: - Argument builders (public for testing / preview)

    public func buildArguments(job: DownloadJob, directory: URL) -> [String] {
        buildArguments(job: job, directory: directory, auth: YouTubeAuth.load())
    }

    func buildArguments(job: DownloadJob, directory: URL, auth: YouTubeAuth) -> [String] {
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
        // Download on the anonymous-first chain; cookies (if any) ride along.
        // PO-token plugin flags are appended when a runtime + plugins exist.
        if let chain = auth.clientChains().first {
            args += YouTubeAuth.clientArgs(for: chain)
        }
        args += pluginArgs()
        args += ["-P", directory.path]
        switch job.kind {
        case .audio:
            args += [
                "-x",
                "--audio-format", job.audioFormat.ytDlpValue,
                "--audio-quality", "0",
                "--embed-thumbnail", "--convert-thumbnails", "jpg",
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

    /// Shared probe prefix: hardening + auth + client + optional POT plugin.
    static func probeBaseArgs(auth: YouTubeAuth, chain: [String]) -> [String] {
        var args = YouTubeAuth.networkArgs
        args += auth.authArgs()
        args += YouTubeAuth.clientArgs(for: chain)
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

    /// Overwrites metadata in place via temp file. Best-effort per format.
    /// WAV: only INFO + BWF chunks are writable — Finder/Music may ignore them (spec limit).
    public func applyTags(to file: URL, tags: TrackTags, format: AudioFormat) async throws {
        guard let ffmpeg = await binaries.ffmpegPath else { return } // no ffmpeg → keep untagged file
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.deletingPathExtension().lastPathComponent).tagged.\(file.pathExtension)")
        var args = ["-y", "-i", file.path]
        args += ["-metadata", "artist=\(tags.artist)"]
        args += ["-metadata", "title=\(tags.title)"]
        args += ["-metadata", "album=\(tags.album)"]
        if let n = tags.trackNumber { args += ["-metadata", "track=\(n)"] }
        if let y = tags.year, !y.isEmpty { args += ["-metadata", "date=\(y)"] }
        if let g = tags.genre, !g.isEmpty { args += ["-metadata", "genre=\(g)"] }
        if format == .mp3 {
            args += ["-id3v2_version", "3", "-write_id3v1", "1", "-c", "copy", tmp.path]
        } else if format == .wav {
            args += ["-c", "copy", "-write_bext", "1", tmp.path]
        } else {
            args += ["-c", "copy", tmp.path]
        }
        _ = try? await runCapture(exe: ffmpeg, args: args, timeout: 60)
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
    static func parseProgress(line: String) -> ProgressUpdate? {
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
final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Tracks in-flight probe processes so `cancelProbes()` can kill them.
/// Lock-guarded (not actor-isolated) because it is driven from GCD blocks.
final class ProbeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var cancelled: Set<UUID> = []

    func register(id: UUID, process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes[id] = process
    }

    func unregister(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        processes.removeValue(forKey: id)
    }

    func wasCancelled(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(id)
    }

    func cancelAll() {
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
    private var done = false
    private let cont: CheckedContinuation<URL, Error>

    init(_ cont: CheckedContinuation<URL, Error>) { self.cont = cont }

    func resume(returning value: URL) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        cont.resume(returning: value)
    }

    func resume(throwing error: Error) {
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
    private var done = false
    private let cont: CheckedContinuation<YTDLPService.CapturedOutput, Error>

    init(_ cont: CheckedContinuation<YTDLPService.CapturedOutput, Error>) { self.cont = cont }

    func resume(returning value: YTDLPService.CapturedOutput) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        cont.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        cont.resume(throwing: error)
    }
}

/// Plain byte buffer for cross-thread pipe draining.
final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Lock-guarded boolean flag.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}
