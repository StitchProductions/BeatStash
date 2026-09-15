import Foundation
import SwiftUI
import UserNotifications

/// Queue + batch state. `@Observable` (Swift 5.9+), `@MainActor` by default
/// per project `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
@Observable
@MainActor
final class DownloadStore {
    // MARK: - Probe / batch draft

    var urlText: String = ""
    var isFetching = false
    var fetchProgress: String?
    var fetchError: String?
    var probeTitle: String?
    var draftJobs: [DownloadJob] = []
    var batchFormat: AudioFormat = .m4a {
        didSet { UserDefaults.standard.set(batchFormat.rawValue, forKey: "defaultAudioFormat") }
    }
    var videoQuality: VideoQuality = .hd1080p
    var batchMode: DownloadKind = .audio
    var destination: URL = AppSettings.destinationRoot

    /// Single write path for the library location — both choosers
    /// (Settings, New Batch) route here so UserDefaults and the live
    /// store can never drift.
    func setDestination(_ url: URL) {
        destination = url
        UserDefaults.standard.set(url.path, forKey: "destinationRoot")
    }

    // MARK: - Queue

    var queue: [DownloadJob] = []
    var history: [HistoryEntry] = []
    var maxConcurrent = 3

    // MARK: - Backend status

    var ytDlpVersion: String?
    var binariesReady = false
    var setupMessage: String?

    // MARK: - Launch gate (yt-dlp must be present and current to proceed)

    var backendReady = false
    var backendStatus = "Locating yt-dlp…"
    var backendError: String?
    var showingTerms = false
    private var gateRan = false

    private let service = YTDLPService()
    private var runningCount = 0
    private var notificationAuthRequested = false
    private var fetchTask: Task<Void, Never>?
    private var fetchSession: UUID?

    init() {
        if let raw = UserDefaults.standard.string(forKey: "defaultAudioFormat"),
           let f = AudioFormat(rawValue: raw) {
            batchFormat = f
        }
        if let dest = UserDefaults.standard.string(forKey: "destinationRoot"), !dest.isEmpty {
            destination = URL(fileURLWithPath: dest)
        }
        maxConcurrent = UserDefaults.standard.integer(forKey: "maxConcurrent")
        if maxConcurrent <= 0 { maxConcurrent = 3 }
        Self.ensureStoreDirs()
        loadHistory()
        loadQueue()
    }

    /// Creates ~/Library/Application Support/BeatStash once per launch.
    /// Getters must not do I/O — they run on every save.
    private static func ensureStoreDirs() {
        guard queueFileOverride == nil, historyFileOverride == nil else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: - Setup

    /// Launch gate entry point. Runs once per launch: terms (first launch),
    /// then presence + forced latest-version integration. Sets `backendReady`
    /// when the main UI may appear.
    func runLaunchGate() async {
        guard !gateRan else { return }
        gateRan = true
        backendError = nil
        if !UserDefaults.standard.bool(forKey: BinaryManager.termsKey) {
            showingTerms = true
            return // agreeTerms() resumes the gate.
        }
        await performGate()
    }

    /// First-launch terms acceptance. Launching = agreeing to yt-dlp auto-updates.
    func agreeTerms() {
        guard showingTerms else { return }
        UserDefaults.standard.set(true, forKey: BinaryManager.termsKey)
        showingTerms = false
        Task { await performGate() }
    }

    func retryLaunchGate() async {
        backendError = nil
        gateRan = false
        await runLaunchGate()
    }

    /// Failure escape hatch: proceed with whatever copy exists (usually the
    /// bundled snapshot). Banners from `bootstrap()` still apply.
    func continueOffline() {
        backendError = nil
        backendReady = true
        restoreQueueAndResume()
        Task { await bootstrap() }
    }

    private func performGate() async {
        backendError = nil
        await BinaryManager.shared.locate()
        // 1. Presence (blocking, local-only): install when nothing usable exists.
        if await BinaryManager.shared.ytDlpPath == nil {
            backendStatus = "Downloading yt-dlp…"
            do {
                _ = try await BinaryManager.shared.ensureYtDlp()
            } catch {
                backendError = error.localizedDescription
                backendStatus = "Download failed."
                return // Retry / Continue offline.
            }
        }
        // 2. Currency: a fresh install blocks on the full fetch once so the
        // first launch integrates the latest. Every launch after that opens
        // instantly while the check runs in the background.
        // (Custom-override users skip the install inside; terms still applied.)
        let firstRun = await BinaryManager.shared.lastCheckDate() == nil
        if firstRun {
            backendStatus = "Checking for yt-dlp updates…"
            let outcome = await BinaryManager.shared.checkAndUpdateIfNeeded(ignoreCache: true)
            switch outcome {
            case .updated(_, let to):
                backendStatus = "yt-dlp v\(to) ready."
            case .upToDate(let v):
                backendStatus = "yt-dlp v\(v) is current."
            case .skipped(let r):
                backendStatus = r
            case .failed(let m):
                backendError = m
                backendStatus = "Couldn't reach GitHub."
                return // Retry / Continue offline.
            }
            await bootstrap()
            backendReady = true
            restoreQueueAndResume()
        } else {
            await bootstrap() // fast: cached check + shared version memo
            backendReady = true
            restoreQueueAndResume()
            Task { await refreshCurrencyInBackground() }
        }
    }

    /// Post-launch currency check. Surfaces a new version (or a
    /// stale-aware banner on failure) without ever blocking the UI.
    /// Skips the second bootstrap unless the version actually changed —
    /// the launch-time state is already current otherwise.
    private func refreshCurrencyInBackground() async {
        let outcome = await BinaryManager.shared.checkAndUpdateIfNeeded(ignoreCache: true)
        if case .updated = outcome {
            await bootstrap()
        }
    }

    func bootstrap() async {
        requestNotificationAuthOnce()
        await BinaryManager.shared.locate()
        // Try silent auto-install of yt-dlp on first launch.
        if await BinaryManager.shared.ytDlpPath == nil {
            setupMessage = "Downloading yt-dlp…"
            do {
                _ = try await BinaryManager.shared.ensureYtDlp()
            } catch {
                setupMessage = "Couldn't auto-install yt-dlp: \(error.localizedDescription)"
            }
        }
        // Refresh the self-updating copy when a newer release exists
        // (24h cache; custom-override paths skip the install inside).
        var updateOutcome: BinaryManager.UpdateOutcome?
        if await BinaryManager.shared.ytDlpPath != nil {
            updateOutcome = await BinaryManager.shared.checkAndUpdateIfNeeded()
        }
        binariesReady = await BinaryManager.shared.isReady
        ytDlpVersion = await BinaryManager.shared.ytDlpVersion()
        if await BinaryManager.shared.ytDlpPath == nil {
            setupMessage = "yt-dlp not found. Check your connection and press Download in Settings."
        } else if await BinaryManager.shared.ffmpegPath == nil {
            setupMessage = "ffmpeg not found — it ships with BeatStash, so reinstall the app or set a custom path in Settings."
        } else if case .updated(let from, let to)? = updateOutcome {
            setupMessage = "yt-dlp auto-updated\(from.map { " from v\($0)" } ?? "") to v\(to)."
        } else if case .failed(let m)? = updateOutcome {
            // Check failed (offline?): nag only when the copy is actually
            // stale. A fresh copy with a failed check stays silent.
            if let age = await BinaryManager.shared.ytDlpAgeDays(), age > 21 {
                setupMessage = "yt-dlp is \(age) days old and couldn't check for updates (\(m)). Press Update in Settings when online."
            } else {
                setupMessage = nil
            }
        } else if await BinaryManager.shared.usesCustomOverride(),
                  let current = ytDlpVersion,
                  let known = await BinaryManager.shared.cachedLatestVersion(),
                  BinaryManager.compareVersions(current, known) == .orderedAscending {
            // Custom binary: can't auto-update it, but point at the release once.
            setupMessage = "yt-dlp update available: v\(current) → v\(known). Update your custom install or clear the override in Settings."
        } else if let age = await BinaryManager.shared.ytDlpAgeDays(), age > 60 {
            // Backstop for copies that somehow never update. Fires rarely —
            // being on latest (or recently checked) never nags.
            setupMessage = "yt-dlp is \(age) days old — YouTube changes often break old versions. Press Check for updates in Settings."
        } else {
            setupMessage = nil
        }
    }

    // MARK: - Fetch

    /// Starts a fetch; safe to call repeatedly (supersedes in-flight fetch).
    func fetch() async {
        fetchTask?.cancel()
        await service.cancelProbes()
        let session = UUID()
        fetchSession = session
        let task = Task { await performFetch(session: session) }
        fetchTask = task
        await task.value
        if fetchSession == session { fetchTask = nil }
    }

    /// Kills the in-flight probe and resets UI state (Cancel button).
    func cancelFetch() {
        fetchTask?.cancel()
        Task { await service.cancelProbes() }
        // performFetch's catch resets isFetching; fast-path it in case
        // the probe already returned between cancel and termination.
        if isFetching { isFetching = false }
    }

    /// Clears fetched drafts (Clear list button). Pasted links stay so the
    /// batch can be edited and re-fetched; destination, format, queue, and
    /// history are untouched. Any in-flight fetch is cancelled and orphaned
    /// via a fresh session so late Tier-2 publishes can't repopulate the list.
    func clearDrafts() {
        cancelFetch()
        fetchTask = nil
        fetchSession = UUID()
        isFetching = false
        fetchProgress = nil
        fetchError = nil
        draftJobs = []
        probeTitle = nil
    }

    /// One-tap Download: instant drafts (disk/oEmbed, ~1s), enqueue everything
    /// in the chosen format, jump to the queue — full details backfill while
    /// downloading. Probe failures surface as `fetchError` with no navigation.
    func fetchAndDownloadAll() async {
        let urls = dedupedURLs(from: urlText)
        guard !urls.isEmpty else {
            fetchError = "Paste a YouTube link, playlist, or video ID."
            return
        }
        fetchTask?.cancel()
        await service.cancelProbes()
        let session = UUID()
        fetchSession = session
        let task = Task { await performFetchThenDownload(session: session, urls: urls) }
        fetchTask = task
        await task.value
        if fetchSession == session { fetchTask = nil }
    }

    /// Draft singles still missing full details (duration/year).
    var needsEnrichment: Bool {
        !isFetching && draftJobs.contains { $0.duration == nil && $0.playlistTitle == nil }
    }

    /// On-demand full details for instant drafts: probes each duration-less
    /// single (serial, throttle-safe), fills in place without touching
    /// user-edited tags, and warms both caches. Playlists expand on fetch;
    /// this never appends rows, so mid-enrich edits can't resurrect anything.
    func enrichDrafts() async {
        let targets = dedupedURLs(from: draftJobs
            .filter { $0.duration == nil && $0.playlistTitle == nil }
            .map(\.url).joined(separator: "\n"))
        guard !targets.isEmpty, !isFetching else { return }
        fetchTask?.cancel()
        await service.cancelProbes()
        let session = UUID()
        fetchSession = session
        let task = Task { await performEnrich(session: session, urls: targets) }
        fetchTask = task
        await task.value
        if fetchSession == session { fetchTask = nil }
    }

    private func performEnrich(session: UUID, urls: [String]) async {
        if Task.isCancelled { return }
        guard fetchSession == session else { return }
        isFetching = true
        fetchProgress = urls.count > 1 ? "Enriching 0/\(urls.count)…" : "Enriching details…"
        defer {
            if fetchSession == session { isFetching = false }
            fetchProgress = nil
        }
        do {
            let outcomes = try await probeAll(urls: urls, label: "Enriching")
            guard fetchSession == session else { return }
            try Task.checkCancellation()
            let merged = mergeTier2(outcomes: outcomes, into: draftJobs, appendMissing: false)
            draftJobs = merged.jobs
            // Durations filling in is the feedback; failures stay silent
            // best-effort top-up (the drafts were already decision-grade).
        } catch is CancellationError {
            guard fetchSession == session else { return }
        } catch {
            guard fetchSession == session else { return }
        }
    }

    private func performFetchThenDownload(session: UUID, urls: [String]) async {
        if Task.isCancelled { return }
        guard fetchSession == session else { return }
        isFetching = true
        fetchError = nil
        draftJobs = []
        probeTitle = nil
        fetchProgress = urls.count > 1 ? "Fetching 0/\(urls.count)…" : nil
        defer {
            if fetchSession == session { isFetching = false }
            fetchProgress = nil
        }
        do {
            // Instant tiers only — downloads start on best-available tags.
            let tier1 = try await buildTier1(urls: urls)
            guard fetchSession == session else { return }
            try Task.checkCancellation()
            var jobs = tier1.jobs
            var failures: [String] = []
            var pending = tier1.pending
            finalizeFetch(urls: urls, jobs: jobs, oEmbedTitles: tier1.titles,
                          pending: pending.count, failures: [])
            // Nothing instant: run the full probe before giving up.
            if jobs.isEmpty, !pending.isEmpty {
                let outcomes = try await probeAll(urls: pending, label: "Fetching")
                guard fetchSession == session else { return }
                try Task.checkCancellation()
                let merged = mergeTier2(outcomes: outcomes, into: jobs)
                jobs = merged.jobs
                failures = merged.failures
                pending = []
                finalizeFetch(urls: urls, jobs: jobs, oEmbedTitles: tier1.titles,
                              pending: 0, failures: failures)
            }
            guard fetchError == nil, !jobs.isEmpty, !Task.isCancelled else { return }
            let now = dedupedURLs(from: urlText)
            guard now == urls else { return } // superseded by new input
            setAllSelected(true)
            enqueueSelected()
            NotificationCenter.default.post(name: .beatStashShowQueue, object: nil)
            // No trailing enrichment: instant drafts are decision-grade by
            // design. Playlists/misses were already resolved above when needed.
        } catch is CancellationError {
            guard fetchSession == session else { return }
            fetchError = nil
        } catch {
            guard fetchSession == session else { return }
            if !Task.isCancelled {
                fetchError = error.localizedDescription
            } else {
                fetchError = nil
            }
        }
    }

    private func performFetch(session: UUID) async {
        if Task.isCancelled { return }
        let urls = dedupedURLs(from: urlText)
        guard fetchSession == session else { return } // superseded — stay quiet
        guard !urls.isEmpty else {
            fetchError = "Paste a YouTube link, playlist, or video ID."
            return
        }
        isFetching = true
        fetchError = nil
        draftJobs = []
        probeTitle = nil
        fetchProgress = urls.count > 1 ? "Fetching 0/\(urls.count)…" : nil
        defer {
            if fetchSession == session { isFetching = false }
            fetchProgress = nil
        }

        do {
            // Tier 0+1: disk cache + instant oEmbed — drafts appear in ~a second.
            let tier1 = try await buildTier1(urls: urls)
            guard fetchSession == session else { return }
            var jobs = tier1.jobs
            var failures: [String] = []
            finalizeFetch(urls: urls, jobs: jobs, oEmbedTitles: tier1.titles,
                          pending: tier1.pending.count, failures: [])
            try Task.checkCancellation()
            // Tier 2: full-probe enrichment (serial, throttle-safe).
            if !tier1.pending.isEmpty {
                if tier1.pending.count == 1, urls.count == 1 { fetchProgress = "Enriching details…" }
                let outcomes = try await probeAll(urls: tier1.pending, label: "Enriching")
                guard fetchSession == session else { return }
                try Task.checkCancellation()
                let merged = mergeTier2(outcomes: outcomes, into: jobs)
                jobs = merged.jobs
                failures = merged.failures
                finalizeFetch(urls: urls, jobs: jobs, oEmbedTitles: tier1.titles,
                              pending: 0, failures: failures)
            }
        } catch is CancellationError {
            // User pressed Cancel (or superseded by a new fetch) — stay quiet.
            guard fetchSession == session else { return }
            fetchError = nil
            draftJobs = []
            probeTitle = nil
        } catch {
            guard fetchSession == session else { return }
            if Task.isCancelled {
                fetchError = nil
            } else {
                fetchError = error.localizedDescription
            }
        }
    }

    /// One pasted link per line, duplicates removed (order preserved).
    private func dedupedURLs(from text: String) -> [String] {
        var seen = Set<String>()
        return URLParser.extractURLs(from: text).filter { seen.insert($0).inserted }
    }

    private struct ProbeOutcome: Sendable {
        var index: Int
        var url: String
        var result: ProbeResult?
        var message: String?
    }

    /// Probes every URL in order. Per-link failures are captured, never
    /// thrown, so one bad link can't sink the batch. Cancellation still throws.
    ///
    /// Deliberately serial: YouTube throttles concurrent extractions from one
    /// IP (measured 3-at-a-time at ~70s with timeouts vs ~13–19s each serially).
    private func probeAll(urls: [String], label: String = "Fetching") async throws -> [ProbeOutcome] {
        var ordered: [ProbeOutcome] = []
        defer { Task { await service.flushProbeCache() } }
        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            do {
                let r = try await service.fetchInfo(url: url)
                ordered.append(ProbeOutcome(index: i, url: url, result: r, message: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                ordered.append(ProbeOutcome(index: i, url: url, result: nil, message: error.localizedDescription))
            }
            if urls.count > 1 { fetchProgress = "\(label) \(ordered.count)/\(urls.count)…" }
        }
        return ordered
    }

    // MARK: - Two-tier fetch (instant oEmbed + enriching probe)

    private struct Tier1Result {
        var jobs: [DownloadJob]
        var titles: [String: String] // playlist URL → oEmbed title
        var pending: [String] // URLs still needing the full probe
    }

    /// Instant draft from oEmbed metadata (no duration/date — those backfill).
    /// Pure: covered by tests.
    static func draftFromOEmbed(
        url: String, video: OEmbedVideo,
        format: AudioFormat, quality: VideoQuality, mode: DownloadKind
    ) -> DownloadJob {
        let tags = TagParser.parse(title: video.title, uploader: video.authorName)
        return DownloadJob(
            url: url,
            kind: mode,
            displayTitle: tags.title.isEmpty ? video.title : tags.title,
            thumbnailURL: video.thumbnailURL,
            audioFormat: format,
            videoQuality: quality,
            tags: tags
        )
    }

    private func makeSingleJob(url: String, media: MediaInfo) -> DownloadJob {
        let tags = TagParser.parse(
            title: media.safeTitle,
            uploader: media.safeUploader,
            playlistTitle: nil,
            playlistIndex: nil,
            uploadDate: media.uploadDate
        )
        return DownloadJob(
            url: url,
            kind: batchMode,
            displayTitle: media.safeTitle,
            thumbnailURL: media.resolvedThumbnail,
            duration: media.duration,
            audioFormat: batchFormat,
            videoQuality: videoQuality,
            tags: tags
        )
    }

    private func makePlaylistJobs(title: String?, entries: [PlaylistEntry]) -> [DownloadJob] {
        entries.map { e in
            let tags = TagParser.parse(
                title: e.safeTitle,
                uploader: e.uploader,
                playlistTitle: title,
                playlistIndex: e.playlistIndex,
                uploadDate: nil
            )
            return DownloadJob(
                url: e.webpageURL,
                kind: .audio, // playlists are audio-first in v1
                playlistTitle: title,
                playlistIndex: e.playlistIndex,
                displayTitle: e.safeTitle,
                thumbnailURL: e.resolvedThumbnail,
                duration: e.duration,
                audioFormat: batchFormat,
                tags: tags
            )
        }
    }

    /// Tier 0 (disk cache, full data) + Tier 1 (oEmbed, ~0.15s/link).
    /// Never throws except on cancellation; everything missed lands in `pending`.
    private func buildTier1(urls: [String]) async throws -> Tier1Result {
        var jobs: [DownloadJob] = []
        var titles: [String: String] = [:]
        var pending: [String] = []
        var done = 0
        for url in urls {
            try Task.checkCancellation()
            if let cached = await service.diskCachedProbe(for: url) {
                switch cached {
                case .single(let media):
                    jobs.append(makeSingleJob(url: url, media: media))
                case .playlist(let title, let entries):
                    jobs += makePlaylistJobs(title: title, entries: entries)
                }
            } else if let video = try await oEmbedOrNil(url) {
                if YTDLPService.isListURL(url) {
                    titles[url] = video.title
                } else {
                    jobs.append(Self.draftFromOEmbed(
                        url: url, video: video,
                        format: batchFormat, quality: videoQuality, mode: batchMode))
                }
                pending.append(url)
            } else {
                pending.append(url)
            }
            done += 1
            if urls.count > 1 { fetchProgress = "Fetching \(done)/\(urls.count)…" }
        }
        return Tier1Result(jobs: jobs, titles: titles, pending: pending)
    }

    /// oEmbed miss that rethrows cancellation (plain `try?` would swallow it).
    private func oEmbedOrNil(_ url: String) async throws -> OEmbedVideo? {
        do {
            return try await service.fetchOEmbed(url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Folds full-probe outcomes into drafts: singles update in place
    /// (never clobbering user-edited tags), playlists append, misses record.
    /// With `appendMissing: false` (on-demand enrich), unknown URLs are
    /// skipped instead of appended, so mid-enrich edits can't resurrect rows.
    private func mergeTier2(outcomes: [ProbeOutcome], into jobs: [DownloadJob], appendMissing: Bool = true) -> (jobs: [DownloadJob], failures: [String]) {
        var jobs = jobs
        var failures: [String] = []
        for o in outcomes {
            switch o.result {
            case .single(let media)?:
                if let i = jobs.firstIndex(where: { $0.url == o.url && $0.playlistTitle == nil }) {
                    jobs[i].duration = media.duration
                    jobs[i].thumbnailURL = media.resolvedThumbnail
                    if !jobs[i].tagsEdited {
                        jobs[i].displayTitle = media.safeTitle
                        jobs[i].tags = TagParser.parse(
                            title: media.safeTitle,
                            uploader: media.safeUploader,
                            playlistTitle: nil,
                            playlistIndex: nil,
                            uploadDate: media.uploadDate
                        )
                    }
                } else if appendMissing {
                    jobs.append(makeSingleJob(url: o.url, media: media))
                }
            case .playlist(let title, let entries)?:
                jobs += makePlaylistJobs(title: title, entries: entries)
            case nil:
                if let m = o.message { failures.append(m) }
            }
        }
        return (jobs, failures)
    }

    /// Publishes drafts + title + destination + error. `pending` = Tier-2
    /// still outstanding (suppresses the total-failure error until it lands).
    private func finalizeFetch(
        urls: [String], jobs: [DownloadJob],
        oEmbedTitles: [String: String], pending: Int, failures: [String]
    ) {
        draftJobs = jobs
        if urls.count == 1, let u = urls.first {
            if let pt = jobs.first(where: { $0.playlistTitle != nil })?.playlistTitle {
                probeTitle = pt
                destination = AppSettings.batchDirectory(playlistTitle: pt)
            } else if YTDLPService.isListURL(u), let t = oEmbedTitles[u] {
                probeTitle = t
                destination = AppSettings.batchDirectory(playlistTitle: t)
            } else if YTDLPService.isListURL(u) {
                probeTitle = pending > 0 ? "Loading playlist…" : nil
            } else {
                probeTitle = jobs.first?.displayTitle
            }
        } else {
            var t = "\(jobs.count) track\(jobs.count == 1 ? "" : "s") from \(urls.count) links"
            if !failures.isEmpty { t += " · \(failures.count) failed" }
            probeTitle = t
        }
        // A total failure surfaces the first error; partial failures ride
        // along in the title while the good tracks stay downloadable.
        if jobs.isEmpty && pending == 0 {
            fetchError = failures.first ?? "Couldn't read video info."
        } else {
            fetchError = nil
        }
    }

    // MARK: - Batch format (two-level picker)

    var selectedDrafts: [DownloadJob] { draftJobs.filter { $0.selected } }

    var estimatedSizeMB: Double {
        selectedDrafts.reduce(0) { acc, j in
            let mins = (j.duration ?? 180) / 60
            return acc + mins * j.audioFormat.mbPerMinute
        }
    }

    var editedTagCount: Int { draftJobs.filter { $0.tagsEdited }.count }
    var overriddenFormatCount: Int { draftJobs.filter { $0.isFormatOverridden }.count }

    /// Header-level default → applies to all non-overridden rows (or all if `force`).
    func applyBatchFormat(_ format: AudioFormat, force: Bool = false) {
        batchFormat = format
        for i in draftJobs.indices {
            if force || !draftJobs[i].isFormatOverridden {
                draftJobs[i].audioFormat = format
                if force { draftJobs[i].isFormatOverridden = false }
            }
        }
    }

    func setPerTrackFormat(id: UUID, format: AudioFormat) {
        guard let i = draftJobs.firstIndex(where: { $0.id == id }) else { return }
        draftJobs[i].audioFormat = format
        draftJobs[i].isFormatOverridden = (format != batchFormat)
    }

    func applyAlbumToAll(_ album: String) {
        for i in draftJobs.indices {
            draftJobs[i].tags.album = album
            draftJobs[i].tagsEdited = true
        }
    }

    func resetTags(id: UUID, playlistTitle: String?) {
        guard let i = draftJobs.firstIndex(where: { $0.id == id }) else { return }
        let j = draftJobs[i]
        draftJobs[i].tags = TagParser.parse(
            title: j.displayTitle, uploader: j.tags.artist,
            playlistTitle: playlistTitle, playlistIndex: j.playlistIndex
        )
        draftJobs[i].tagsEdited = false
    }

    var allSelected: Bool { !draftJobs.isEmpty && draftJobs.allSatisfy { $0.selected } }
    func setAllSelected(_ v: Bool) {
        for i in draftJobs.indices { draftJobs[i].selected = v }
    }

    // MARK: - Enqueue + run

    func enqueueSelected() {
        let dir = destination
        let selected = selectedDrafts
        for var job in selected {
            job.status = .queued
            job.progress = 0
            job.errorMessage = nil
            // Snapshot destination into outputPath directory prefix.
            job.outputPath = dir.path
            queue.append(job)
        }
        // Clear draft selection to avoid double-enqueue.
        for i in draftJobs.indices { draftJobs[i].selected = false }
        saveQueue()
        pump()
    }

    func retry(id: UUID) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].status = .queued
        queue[i].progress = 0
        queue[i].phaseLabel = nil
        queue[i].errorMessage = nil
        queue[i].tagNote = nil
        transientFailures.removeValue(forKey: id)
        stopPreparingTicker(id)
        saveQueue()
        pump()
    }

    func cancel(id: UUID) {
        Task { await service.cancel(id: id) }
        preparingIDs.remove(id)
        stopPreparingTicker(id)
        transientFailures.removeValue(forKey: id)
        if let i = queue.firstIndex(where: { $0.id == id }) {
            if queue[i].status.isActive {
                queue[i].status = .cancelled
            }
        }
        saveQueue()
        pump()
    }

    func cancelAll() {
        for j in queue where j.status.isActive {
            Task { await service.cancel(id: j.id) }
            preparingIDs.remove(j.id)
            stopPreparingTicker(j.id)
            transientFailures.removeValue(forKey: j.id)
        }
        for i in queue.indices where queue[i].status.isActive {
            queue[i].status = .cancelled
        }
        saveQueue()
    }

    /// Clears finished rows at the user's request. Completed rows move into
    /// history here — not at download time — so a relaunch never loses them
    /// before they've been seen; failed/cancelled rows are dropped silently.
    func clearFinished() {
        for job in queue.filter({ $0.status == .completed }) {
            history.insert(HistoryEntry(
                title: job.tags.title.isEmpty ? job.displayTitle : job.tags.title,
                artist: job.tags.artist,
                url: job.url,
                format: job.kind == .audio ? job.audioFormat.rawValue : job.videoQuality.rawValue,
                filePath: job.outputPath ?? "",
                thumbnailURL: job.thumbnailURL
            ), at: 0)
        }
        let cleared = queue.filter { $0.status.isFinished }.map(\.id)
        queue.removeAll { $0.status.isFinished }
        for id in cleared { transientFailures.removeValue(forKey: id) }
        saveHistory()
        saveQueue()
    }

    var activeCount: Int { queue.filter { $0.status.isActive }.count }
    var finishedCount: Int { queue.filter { $0.status == .completed }.count }

    /// Jobs started but not yet streaming progress (extracting/preparing).
    /// Shown as an indeterminate "Preparing…" row state in the queue.
    var preparingIDs: Set<UUID> = []

    /// Extraction start per preparing job (for the elapsed ticker) + the
    /// ticker tasks themselves. MainActor-confined like everything here.
    private var preparingInfo: [UUID: Date] = [:]
    private var preparingTickers: [UUID: Task<Void, Never>] = [:]

    /// Ticks `Preparing… · Ns` once a second while a job is still extracting,
    /// so a slow player-API call reads as alive, not frozen. Stops the moment
    /// bytes flow (preparingIDs cleared), the job settles, or it cancels.
    private func startPreparingTicker(_ id: UUID) {
        preparingTickers[id]?.cancel()
        preparingTickers[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.preparingIDs.contains(id),
                          let i = self.queue.firstIndex(where: { $0.id == id }),
                          let start = self.preparingInfo[id],
                          let phase = self.queue[i].phaseLabel,
                          phase.hasPrefix("Preparing") else { return }
                    let base = YTDLPService.strippingElapsedSuffix(phase)
                    let secs = Int(Date().timeIntervalSince(start))
                    // No-op guard: before 2s the label is just `base` — don't
                    // invalidate the whole store every second for no change.
                    let next = secs >= 2 ? "\(base) · \(secs)s" : base
                    if self.queue[i].phaseLabel != next {
                        self.queue[i].phaseLabel = next
                    }
                }
            }
        }
    }

    private func stopPreparingTicker(_ id: UUID) {
        preparingTickers.removeValue(forKey: id)?.cancel()
        preparingInfo.removeValue(forKey: id)
    }

    /// Transient-failure counts for bounded auto-requeue (in-memory only:
    /// a relaunch starts every job with a clean slate).
    private var transientFailures: [UUID: Int] = [:]

    private func pump() {
        // Launch up to maxConcurrent queued jobs.
        while runningCount < maxConcurrent,
              let next = queue.first(where: { $0.status == .queued }) {
            run(jobID: next.id)
        }
    }

    /// Relaunch status mapping. Nil = stays as-is (already queued rows just
    /// need pump; cancelled/completed wait for the user). Interrupted work
    /// and failed rows requeue. Pure (tested).
    nonisolated static func restoredStatus(for status: JobStatus) -> JobStatus? {
        switch status {
        case .downloading, .tagging, .fetching, .failed:
            return .queued
        case .pending, .queued, .cancelled, .completed:
            return nil
        }
    }

    /// Launch recovery runs once (a repeat must never yank running downloads
    /// back to queued).
    private var queueRestored = false

    /// Relaunch recovery: requeues interrupted + failed rows and pumps.
    /// Called once the launch gate passes so binaries exist before anything
    /// starts.
    func restoreQueueAndResume() {
        if !queueRestored {
            queueRestored = true
            if normalizeQueueForResume() { saveQueue() }
        }
        pump()
    }

    /// Applies the relaunch mapping without pumping (testable half of
    /// restore; pump would spawn real downloads). Returns whether anything
    /// was requeued.
    @discardableResult
    func normalizeQueueForResume() -> Bool {
        var resumed = false
        for i in queue.indices {
            guard let next = Self.restoredStatus(for: queue[i].status) else { continue }
            queue[i].status = next
            queue[i].progress = 0
            queue[i].phaseLabel = nil
            queue[i].speedString = nil
            queue[i].etaString = nil
            queue[i].errorMessage = nil
            transientFailures.removeValue(forKey: queue[i].id)
            resumed = true
        }
        return resumed
    }

    private func run(jobID: UUID) {
        guard let idx = queue.firstIndex(where: { $0.id == jobID }) else { return }
        queue[idx].status = .downloading
        preparingIDs.insert(jobID)
        preparingInfo[jobID] = Date()
        runningCount += 1
        let job = queue[idx]
        let dir = URL(fileURLWithPath: job.outputPath ?? destination.path)
        let runStart = preparingInfo[jobID] ?? Date()
        startPreparingTicker(jobID)
        saveQueue()

        Task {
            do {
                let stream = await service.download(job: job, to: dir)
                // Coalesce fraction-only ticks to ~5Hz: yt-dlp emits lines far
                // faster than the eye (or SwiftUI) needs. Phase changes and
                // completion always flush immediately — same end state, ~10x
                // fewer MainActor hops and store invalidations.
                var lastFlush = Date.distantPast
                for try await update in stream {
                    let isPhase = update.phase != nil
                    let isDone = update.fraction >= 1
                    if !isPhase, !isDone, update.fraction > 0,
                       Date().timeIntervalSince(lastFlush) < 0.2 { continue }
                    lastFlush = Date()
                    await MainActor.run {
                        if let i = self.queue.firstIndex(where: { $0.id == jobID }) {
                            if update.fraction > 0 {
                                self.queue[i].progress = update.fraction
                                self.queue[i].speedString = update.speed
                                self.queue[i].etaString = update.eta
                                self.preparingIDs.remove(jobID)
                            }
                            if let phase = update.phase {
                                self.queue[i].phaseLabel = phase
                            } else if update.fraction > 0 {
                                self.queue[i].phaseLabel = nil
                            }
                        }
                    }
                }
                // Bytes done. Prefer yt-dlp's own reported path
                // (`--print after_move:filepath`); the directory scan is only
                // a fallback for older/odd outputs. Free the concurrency slot
                // BEFORE any ffmpeg tag pass so tagging never stalls the queue.
                // Tagging runs only when the user edited tags or supplied
                // artwork — untouched rows keep yt-dlp's embedded metadata
                // as-is (and skip the WAV rewrite stall entirely).
                // Videos skip tagging entirely.
                let needsTagging = job.kind == .audio
                    && (job.tagsEdited || !(job.artworkURL?.isEmpty ?? true))
                var finalPath: String? = await service.takeFinishedPath(for: jobID)?.path
                if finalPath == nil {
                    finalPath = YTDLPService.newestFile(in: dir, matching: job)?.path
                }
                await MainActor.run {
                    self.preparingIDs.remove(jobID)
                    self.stopPreparingTicker(jobID)
                    if let i = self.queue.firstIndex(where: { $0.id == jobID }), needsTagging {
                        self.queue[i].status = .tagging
                        self.queue[i].phaseLabel = "Tagging…"
                    }
                    self.runningCount = max(0, self.runningCount - 1)
                    self.saveQueue()
                    self.pump()
                }
                var tagsApplied = true
                if needsTagging, let path = finalPath {
                    tagsApplied = (try? await service.applyTags(
                        to: URL(fileURLWithPath: path), tags: job.tags,
                        format: job.audioFormat, artworkURL: job.artworkURL)) ?? false
                }
                // Tagging replaces in place, so the download path stays
                // correct; only fall back to a scan if somehow the file isn't
                // where yt-dlp said it put it (and only trust files, since a
                // confirmed directory would mislead Finder-reveal later).
                var resolvedPath: String? = finalPath
                var isDir: ObjCBool = false
                if let p = resolvedPath,
                   FileManager.default.fileExists(atPath: p, isDirectory: &isDir),
                   !isDir.boolValue {
                    // exact file confirmed — no scan needed.
                } else {
                    resolvedPath = YTDLPService.newestFile(in: dir, matching: job)?.path
                }
                // WAV never embeds covers, so any same-stem image born during
                // this run is thumbnail residue from a failed/old flow — sweep
                // it so the music folder holds just the audio. Best-effort;
                // user art (other stems, older mtimes) is never touched.
                if job.kind == .audio, job.audioFormat == .wav, let p = resolvedPath {
                    let outputURL = URL(fileURLWithPath: p)
                    for residue in YTDLPService.thumbnailResidueCandidates(
                        output: outputURL, in: dir, since: runStart) {
                        try? FileManager.default.removeItem(at: residue)
                    }
                }
                await MainActor.run {
                    self.preparingIDs.remove(jobID)
                    self.stopPreparingTicker(jobID)
                    self.transientFailures.removeValue(forKey: jobID)
                    if let i = self.queue.firstIndex(where: { $0.id == jobID }),
                       self.queue[i].status == (needsTagging ? .tagging : .downloading) {
                        self.queue[i].status = .completed
                        self.queue[i].progress = 1
                        self.queue[i].phaseLabel = nil
                        // A failed tag pass keeps the audio but says so on the row.
                        self.queue[i].tagNote = tagsApplied ? nil : "Tags not applied — file kept as downloaded"
                        if let p = resolvedPath {
                            self.queue[i].outputPath = p
                        }
                        // History is filled at Clear-finished time, not here,
                        // so completed rows survive a relaunch until seen.
                        self.saveQueue()
                    }
                    self.notify(title: "Download finished", body: job.displayTitle)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.preparingIDs.remove(jobID)
                    self.stopPreparingTicker(jobID)
                    if let i = self.queue.firstIndex(where: { $0.id == jobID }) {
                        self.queue[i].status = .cancelled
                    }
                    self.runningCount = max(0, self.runningCount - 1)
                    self.saveQueue()
                    self.pump()
                }
            } catch {
                await MainActor.run {
                    self.preparingIDs.remove(jobID)
                    self.stopPreparingTicker(jobID)
                    let used = self.transientFailures[jobID] ?? 0
                    if YTDLPService.shouldAutoRequeue(error: error, attemptsUsed: used),
                       let i = self.queue.firstIndex(where: { $0.id == jobID }) {
                        // Transient (stale player session, healed network):
                        // back to the queue for a pump-paced retry instead of
                        // failing outright. Cap enforced by the policy.
                        self.transientFailures[jobID] = used + 1
                        self.queue[i].status = .queued
                        self.queue[i].progress = 0
                        self.queue[i].phaseLabel = nil
                        self.queue[i].errorMessage = "Auto-retrying (attempt \(used + 2)/3)…"
                    } else if let i = self.queue.firstIndex(where: { $0.id == jobID }) {
                        self.transientFailures.removeValue(forKey: jobID)
                        self.queue[i].status = .failed
                        self.queue[i].errorMessage = error.localizedDescription
                    }
                    self.runningCount = max(0, self.runningCount - 1)
                    self.saveQueue()
                    self.pump()
                }
            }
        }
    }

    // MARK: - History persistence (JSON, lightweight v1)

    private var historyURL: URL {
        if let override = Self.historyFileOverride { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    /// Test seam: redirect the history file (headless + Xcode tests).
    @MainActor static var historyFileOverride: URL?

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        history = decoded
    }

    private func saveHistory() {
        let trimmed = Array(history.prefix(500))
        if let data = try? JSONEncoder().encode(trimmed) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    // MARK: - Queue persistence (crash-safe, lightweight v1)

    /// Versioned wrapper so future shapes fail soft (empty queue, never a
    /// launch crash) instead of decoding garbage into rows.
    private nonisolated struct PersistedQueue: Codable {
        var version: Int
        var jobs: [DownloadJob]
    }

    private var queueURL: URL {
        if let override = Self.queueFileOverride { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    /// Test seam: redirect the queue file (headless + Xcode tests).
    @MainActor static var queueFileOverride: URL?

    /// Decode helper kept pure for tests (corrupt input → nil, never throws).
    nonisolated static func decodeQueue(from data: Data) -> [DownloadJob]? {
        guard let wrapper = try? JSONDecoder().decode(PersistedQueue.self, from: data),
              wrapper.version == 1 else { return nil }
        return wrapper.jobs
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueURL),
              let jobs = Self.decodeQueue(from: data) else { return }
        queue = jobs.map { job in
            var job = job
            // Live progress never survives a relaunch; settled rows keep
            // their state (failed keeps its message, completed its path).
            // Stale "Auto-retrying…" notes on queued rows are cleared since
            // the attempt they belonged to is gone.
            if job.status.isActive {
                job.progress = 0
                job.speedString = nil
                job.etaString = nil
                job.phaseLabel = nil
                if job.status == .queued { job.errorMessage = nil }
            }
            return job
        }
    }

    /// Synchronous + atomic: cheap (~1KB/job) and crash-safe. Called at every
    /// queue mutation so quit/kill loses nothing.
    private func saveQueue() {
        let wrapper = PersistedQueue(version: 1, jobs: queue)
        if let data = try? JSONEncoder().encode(wrapper) {
            try? data.write(to: queueURL, options: .atomic)
        }
    }

    // MARK: - Notifications

    private func requestNotificationAuthOnce() {
        guard !notificationAuthRequested else { return }
        notificationAuthRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
