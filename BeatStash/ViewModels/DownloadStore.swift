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
        loadHistory()
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
        } else {
            await bootstrap() // fast: cached check + shared version memo
            backendReady = true
            Task { await refreshCurrencyInBackground() }
        }
    }

    /// Post-launch currency check. Surfaces a new version (or a
    /// stale-aware banner on failure) without ever blocking the UI.
    private func refreshCurrencyInBackground() async {
        _ = await BinaryManager.shared.checkAndUpdateIfNeeded(ignoreCache: true)
        await bootstrap()
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

    /// One-tap Download: probes the URL (cache-aware), selects every track,
    /// enqueues in the chosen format, and asks the UI to show the queue.
    /// Probe failures surface as `fetchError` with no navigation.
    func fetchAndDownloadAll() async {
        let urls = URLParser.extractURLs(from: urlText)
        guard urls.first != nil else {
            fetchError = "Paste a YouTube link, playlist, or video ID."
            return
        }
        await fetch()
        guard fetchError == nil, !draftJobs.isEmpty, !Task.isCancelled else { return }
        // Only proceed if the drafts still belong to the links we started with
        // (the user may have typed new links mid-probe, superseding us).
        let now = URLParser.extractURLs(from: urlText)
        guard now == urls else { return }
        setAllSelected(true)
        enqueueSelected()
        NotificationCenter.default.post(name: .beatStashShowQueue, object: nil)
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
            let outcomes = try await probeAll(urls: urls)
            guard fetchSession == session else { return } // superseded mid-probe
            try Task.checkCancellation()
            var jobs: [DownloadJob] = []
            var failureMessages: [String] = []
            for o in outcomes {
                switch o.result {
                case .single(let media)?:
                    let tags = TagParser.parse(
                        title: media.safeTitle,
                        uploader: media.safeUploader,
                        playlistTitle: nil,
                        playlistIndex: nil,
                        uploadDate: media.uploadDate
                    )
                    jobs.append(DownloadJob(
                        url: o.url,
                        kind: batchMode,
                        displayTitle: media.safeTitle,
                        thumbnailURL: media.thumbnail,
                        duration: media.duration,
                        audioFormat: batchFormat,
                        videoQuality: videoQuality,
                        tags: tags
                    ))
                case .playlist(let title, let entries)?:
                    for e in entries {
                        let tags = TagParser.parse(
                            title: e.safeTitle,
                            uploader: e.uploader,
                            playlistTitle: title,
                            playlistIndex: e.playlistIndex,
                            uploadDate: nil
                        )
                        jobs.append(DownloadJob(
                            url: e.webpageURL,
                            kind: .audio, // playlists are audio-first in v1
                            playlistTitle: title,
                            playlistIndex: e.playlistIndex,
                            displayTitle: e.safeTitle,
                            thumbnailURL: e.thumbnail,
                            duration: e.duration,
                            audioFormat: batchFormat,
                            tags: tags
                        ))
                    }
                case nil:
                    if let m = o.message { failureMessages.append(m) }
                }
            }
            draftJobs = jobs
            if urls.count == 1, let only = outcomes.first,
               case .playlist(let title, _) = only.result {
                // Single-playlist fetch: title + batch directory follow it.
                probeTitle = title ?? "Playlist (\(jobs.count) tracks)"
                destination = AppSettings.batchDirectory(playlistTitle: title)
            } else if urls.count == 1 {
                probeTitle = jobs.first?.displayTitle
            } else {
                var t = "\(jobs.count) track\(jobs.count == 1 ? "" : "s") from \(urls.count) links"
                if !failureMessages.isEmpty { t += " · \(failureMessages.count) failed" }
                probeTitle = t
            }
            // A total failure surfaces the first error; partial failures ride
            // along in the title while the good tracks stay downloadable.
            if jobs.isEmpty {
                fetchError = failureMessages.first ?? "Couldn't read video info."
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
    private func probeAll(urls: [String]) async throws -> [ProbeOutcome] {
        var ordered: [ProbeOutcome] = []
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
            if urls.count > 1 { fetchProgress = "Fetching \(ordered.count)/\(urls.count)…" }
        }
        return ordered
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
        pump()
    }

    func retry(id: UUID) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].status = .queued
        queue[i].progress = 0
        queue[i].errorMessage = nil
        pump()
    }

    func cancel(id: UUID) {
        Task { await service.cancel(id: id) }
        if let i = queue.firstIndex(where: { $0.id == id }) {
            if queue[i].status.isActive {
                queue[i].status = .cancelled
            }
        }
        pump()
    }

    func cancelAll() {
        for j in queue where j.status.isActive {
            Task { await service.cancel(id: j.id) }
        }
        for i in queue.indices where queue[i].status.isActive {
            queue[i].status = .cancelled
        }
    }

    func clearFinished() {
        queue.removeAll { $0.status.isFinished }
    }

    var activeCount: Int { queue.filter { $0.status.isActive }.count }
    var finishedCount: Int { queue.filter { $0.status == .completed }.count }

    private func pump() {
        // Launch up to maxConcurrent queued jobs.
        while runningCount < maxConcurrent,
              let next = queue.first(where: { $0.status == .queued }) {
            run(jobID: next.id)
        }
    }

    private func run(jobID: UUID) {
        guard let idx = queue.firstIndex(where: { $0.id == jobID }) else { return }
        queue[idx].status = .downloading
        runningCount += 1
        let job = queue[idx]
        let dir = URL(fileURLWithPath: job.outputPath ?? destination.path)

        Task {
            do {
                let stream = await service.download(job: job, to: dir)
                var finalPath: String?
                for try await update in stream {
                    await MainActor.run {
                        if let i = self.queue.firstIndex(where: { $0.id == jobID }) {
                            self.queue[i].progress = update.fraction
                            self.queue[i].speedString = update.speed
                            self.queue[i].etaString = update.eta
                        }
                    }
                }
                // Resolve newest file for history (service already tagged).
                finalPath = await self.newestPath(in: dir)
                await MainActor.run {
                    if let i = self.queue.firstIndex(where: { $0.id == jobID }) {
                        self.queue[i].status = .completed
                        self.queue[i].progress = 1
                        self.queue[i].outputPath = finalPath ?? self.queue[i].outputPath
                        let done = self.queue[i]
                        self.history.insert(HistoryEntry(
                            title: done.tags.title.isEmpty ? done.displayTitle : done.tags.title,
                            artist: done.tags.artist,
                            url: done.url,
                            format: done.kind == .audio ? done.audioFormat.rawValue : done.videoQuality.rawValue,
                            filePath: done.outputPath ?? "",
                            thumbnailURL: done.thumbnailURL
                        ), at: 0)
                        self.saveHistory()
                    }
                    self.runningCount = max(0, self.runningCount - 1)
                    self.notify(title: "Download finished", body: job.displayTitle)
                    self.pump()
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let i = self.queue.firstIndex(where: { $0.id == jobID }) {
                        self.queue[i].status = .cancelled
                    }
                    self.runningCount = max(0, self.runningCount - 1)
                    self.pump()
                }
            } catch {
                await MainActor.run {
                    if let i = self.queue.firstIndex(where: { $0.id == jobID }) {
                        // yt-dlp terminate() surfaces as non-zero exit → mark cancelled if user asked.
                        if (error as? YTDLPService.ServiceError) != nil {
                            self.queue[i].status = .failed
                            self.queue[i].errorMessage = error.localizedDescription
                        } else {
                            self.queue[i].status = .failed
                            self.queue[i].errorMessage = error.localizedDescription
                        }
                    }
                    self.runningCount = max(0, self.runningCount - 1)
                    self.pump()
                }
            }
        }
    }

    private nonisolated func newestPath(in dir: URL) async -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        var newest: URL?
        var newestDate = Date.distantPast
        for url in items {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date > newestDate {
                newestDate = date
                newest = url
            }
        }
        return newest?.path
    }

    // MARK: - History persistence (JSON, lightweight v1)

    private var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BeatStash", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        history = decoded
    }

    private func saveHistory() {
        let trimmed = Array(history.prefix(500))
        if let data = try? JSONEncoder().encode(trimmed) {
            try? data.write(to: historyURL)
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
