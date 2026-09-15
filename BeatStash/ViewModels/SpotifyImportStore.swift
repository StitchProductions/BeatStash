import Foundation
import Observation

/// One Spotify track through the import pipeline.
public struct SpotifyImportTrack: Identifiable, Sendable {
    public var id: String // Spotify track ID
    public var title: String
    public var artist: String
    public var artworkURL: String?
    public var deezerDuration: Double?
    public var deezerAlbum: String?
    public var status: Status
    public var selected: Bool

    public enum Status: Sendable {
        case working
        case matched(score: Double, youtubeID: String, youtubeTitle: String,
                     duration: Double?, exact: Bool)
        case failed(String)
    }

    public init(id: String, title: String = "…", artist: String = "",
                artworkURL: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.status = .working
        self.selected = false
    }

    public var matchScore: Double? {
        if case .matched(let score, _, _, _, _) = status { return score }
        return nil
    }

    public var isMatched: Bool {
        if case .matched = status { return true }
        return false
    }
}

/// Spotify → YouTube import: playlist/track links in, matched drafts out.
///
/// Pipeline per track (all serial — every surface throttles or paces):
/// oEmbed metadata (~0.2s) + Deezer anchor (~0.3s) → `ytsearch5` (~13s) →
/// score → optional MusicBrainz confidence check when uncertain
/// (paced ≥1.1s, silent degrade; OFF by default — see Settings).
/// The search per song always runs (first import); the toggle only adds or
/// removes the MusicBrainz step — and the score badges, which follow it.
/// Matches land in the New Batch drafts; nothing downloads from here.
@Observable
final class SpotifyImportStore {
    /// UserDefaults key for the optional post-score MusicBrainz check.
    /// OFF by default: enabling slows matching (2+ extra requests per
    /// ambiguous track). Settings toggles this via @AppStorage on the same key.
    /// Row score badges also follow this flag (no score UI when off), while
    /// internal scoring + auto-select always run to pick the match.
    static let confidenceCheckKey = "spotifyConfidenceCheckEnabled"

    /// Live read-through so Settings (@AppStorage) and the store never drift.
    static var confidenceCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: confidenceCheckKey) as? Bool ?? false
    }

    /// Instance access for views/tests (computed — source of truth is UserDefaults).
    var enableConfidenceCheck: Bool {
        get { Self.confidenceCheckEnabled }
        set { UserDefaults.standard.set(newValue, forKey: Self.confidenceCheckKey) }
    }

    /// Badge text for a matched row, or nil when badges are off. With the
    /// check off there is no score UI at all (scoring still runs internally
    /// to pick the match and drive auto-select). Pure (tested).
    nonisolated static func confidenceBadgeText(score: Double, exact: Bool, enabled: Bool) -> String? {
        guard enabled else { return nil }
        if exact { return "Exact" }
        return "\(Int((score * 100).rounded()))% confidence"
    }

    var urlText: String = ""
    var isImporting = false
    var progress: String?
    var errorMessage: String?
    var playlistTitle: String?
    var tracks: [SpotifyImportTrack] = []

    /// Phase-B start per working row (for the "Matching… · Ns" ticker).
    /// Set when a row begins matching, cleared when it settles.
    var matchingStartedAt: [String: Date] = [:]

    /// Header progress state for the elapsed ticker (Phase B only).
    private var matchProgressState: (done: Int, total: Int, start: Date)?
    private var progressTicker: Task<Void, Never>?

    /// Header progress with elapsed ("Matching 12/58… · 3:12").
    /// Pure (tested).
    nonisolated static func matchingProgress(done: Int, total: Int, elapsed: TimeInterval) -> String {
        let base = total <= 1 ? "Matching…" : "Matching \(done + 1)/\(total)…"
        let secs = Int(elapsed)
        guard secs >= 2 else { return base }
        return "\(base) · \(elapsedString(secs))"
    }

    /// Row suffix (" · 0:45"), empty until the stall is real. Pure (tested).
    nonisolated static func matchingElapsedSuffix(since: Date?, now: Date) -> String {
        guard let since else { return "" }
        let secs = Int(now.timeIntervalSince(since))
        guard secs >= 2 else { return "" }
        return " · \(elapsedString(secs))"
    }

    nonisolated static func elapsedString(_ secs: Int) -> String {
        "\(secs / 60):\(String(format: "%02d", secs % 60))"
    }

    /// Re-stamps header progress once a second while Phase-B matching runs,
    /// so a long single search reads as alive, not frozen.
    private func startProgressTicker() {
        progressTicker?.cancel()
        progressTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.isImporting,
                          let st = self.matchProgressState else { return }
                    self.progress = Self.matchingProgress(
                        done: st.done, total: st.total,
                        elapsed: Date().timeIntervalSince(st.start))
                }
            }
        }
    }

    private func stopProgressTicker() {
        progressTicker?.cancel()
        progressTicker = nil
        matchProgressState = nil
    }

    private var importTask: Task<Void, Never>?
    private var importSession: UUID?
    private let service = YTDLPService()

    /// Politeness gap between searches (the per-search 5s/15s backoff is the
    /// real throttle protection; this just avoids burst spawns).
    private static let interSearchDelay: TimeInterval = 0.5

    /// Session memo by Spotify track ID (re-imports don't re-search).
    /// Disk match cache (30d, same key) survives relaunches; both store the
    /// full outcome including low scores (an answer is an answer for 30 days).
    private struct Memo: Sendable {
        var title: String
        var artist: String
        var artworkURL: String?
        var score: Double
        var youtubeID: String
        var youtubeTitle: String
        var duration: Double?
        var exact: Bool
    }
    private var memo: [String: Memo] = [:]
    private var diskMatches: [String: CachedMatch]?

    var matchedCount: Int {
        tracks.filter { if case .matched = $0.status { true } else { false } }.count
    }

    var failedCount: Int {
        tracks.filter { if case .failed = $0.status { true } else { false } }.count
    }

    var selectedCount: Int {
        tracks.filter { $0.selected }.count
    }

    /// Selected rows that are actually addable (matched). The Add button
    /// promises this count — `selectedCount` can include .working/.failed
    /// rows when Select-all ran mid-import, which handoff must skip.
    var selectedMatchedCount: Int {
        tracks.filter { $0.selected && $0.isMatched }.count
    }

    /// Add is only available once matching has settled (prevents the
    /// "button said 50, New Batch got 1" trap from adding mid-import).
    var canAddToBatch: Bool {
        !isImporting && selectedMatchedCount > 0
    }

    /// Select-all state over match-selectable rows only (per-row toggles are
    /// disabled for non-matched, so Select-all must not tick them either).
    var allSelectableSelected: Bool {
        let selectable = tracks.filter { $0.isMatched }
        return !selectable.isEmpty && selectable.allSatisfy { $0.selected }
    }

    func setAllSelectable(_ v: Bool) {
        for i in tracks.indices where tracks[i].isMatched {
            tracks[i].selected = v
        }
    }

    // MARK: - Import

    func importFromURL() async {
        importTask?.cancel()
        await service.cancelProbes()
        let session = UUID()
        importSession = session
        let task = Task { await performImport(session: session) }
        importTask = task
        await task.value
        if importSession == session { importTask = nil }
    }

    func cancelImport() {
        importTask?.cancel()
        Task { await service.cancelProbes() }
        stopProgressTicker()
        if isImporting { isImporting = false }
    }

    /// Clears imported tracks (Clear all button). The pasted link stays so
    /// the import can be edited and re-run; session memo + disk match cache
    /// stay too, so re-importing stays instant. Any in-flight import is
    /// cancelled and orphaned via a fresh session so late publishes can't
    /// repopulate the list.
    func clearTracks() {
        cancelImport()
        importTask = nil
        importSession = UUID()
        isImporting = false
        progress = nil
        errorMessage = nil
        tracks = []
        playlistTitle = nil
        matchingStartedAt.removeAll()
    }

    private func performImport(session: UUID) async {
        if Task.isCancelled { return }
        guard importSession == session else { return }
        guard let (kind, id) = SpotifyService.parseLink(urlText) else {
            errorMessage = "Paste a public Spotify playlist or track link."
            return
        }
        isImporting = true
        errorMessage = nil
        tracks = []
        matchingStartedAt.removeAll()
        stopProgressTicker()
        playlistTitle = nil
        progress = "Reading Spotify…"
        defer {
            if importSession == session { isImporting = false }
            progress = nil
            stopProgressTicker()
        }

        do {
            let ids: [String]
            switch kind {
            case .playlist:
                let (name, trackIDs) = try await SpotifyService.fetchPlaylist(id: id)
                guard importSession == session else { return }
                playlistTitle = name
                ids = trackIDs
                if ids.isEmpty {
                    errorMessage = "No tracks found — is the playlist public?"
                    return
                }
            case .track:
                playlistTitle = nil
                ids = [id]
            }
            var done = 0
            diskMatches = YouTubeMatcher.readMatchCache()
            // Phase A: rows + Tier-1 metadata (4-wide chunks — cheap surfaces).
            for trackID in ids {
                tracks.append(SpotifyImportTrack(id: trackID))
            }
            try await resolveTier1Chunked(ids: ids)
            guard importSession == session else { return }
            // Phase B: serial matching (throttle-proven) with inter-search pacing.
            let matchStart = Date()
            matchProgressState = (done: 0, total: ids.count, start: matchStart)
            startProgressTicker()
            for (idx, trackID) in ids.enumerated() {
                try Task.checkCancellation()
                guard importSession == session else { return }
                if done > 0 {
                    try await Task.sleep(nanoseconds: UInt64(Self.interSearchDelay * 1_000_000_000))
                    guard importSession == session else { return }
                }
                matchProgressState = (done: done, total: ids.count, start: matchStart)
                progress = Self.matchingProgress(
                    done: done, total: ids.count,
                    elapsed: Date().timeIntervalSince(matchStart))
                await matchRow(at: idx, id: trackID)
                done += 1
            }
            matchProgressState = nil
            stopProgressTicker()
        } catch is CancellationError {
            guard importSession == session else { return }
            errorMessage = nil
        } catch {
            guard importSession == session else { return }
            errorMessage = Task.isCancelled ? nil : error.localizedDescription
        }
    }

    /// Phase A: Spotify metadata + Deezer anchors for every row, 4 at a time.
    /// Cheap official-API GETs on distinct hosts — safe to parallelize (unlike
    /// ytsearch). Rows are pre-created, so the list keeps playlist order.
    /// Throws only on cancellation; per-track misses mark their row failed.
    private func resolveTier1Chunked(ids: [String]) async throws {
        struct Tier1: Sendable {
            var index: Int
            var title: String?
            var artist: String?
            var artworkURL: String?
            var deezerDuration: Double?
            var deezerAlbum: String?
            var message: String?
        }
        for start in stride(from: 0, to: ids.count, by: 4) {
            try Task.checkCancellation()
            let end = min(start + 4, ids.count)
            try await withThrowingTaskGroup(of: Tier1.self) { group in
                for idx in start..<end {
                    let id = ids[idx]
                    group.addTask {
                        try Task.checkCancellation()
                        do {
                            let meta = try await SpotifyService.fetchTrackMeta(id: id)
                            let deezer = await DeezerClient.search(
                                artist: meta.artist, title: meta.title)
                            return Tier1(
                                index: idx, title: meta.title,
                                artist: meta.artist.isEmpty
                                    ? (deezer?.artistName ?? "") : meta.artist,
                                artworkURL: meta.artworkURL,
                                deezerDuration: deezer?.duration.map(Double.init),
                                deezerAlbum: deezer?.albumName,
                                message: nil)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return Tier1(index: idx, title: nil, artist: nil,
                                         artworkURL: nil, deezerDuration: nil,
                                         deezerAlbum: nil,
                                         message: error.localizedDescription)
                        }
                    }
                }
                for try await r in group {
                    guard tracks.indices.contains(r.index) else { continue }
                    if let title = r.title {
                        tracks[r.index].title = title
                        tracks[r.index].artist = r.artist ?? ""
                        tracks[r.index].artworkURL = r.artworkURL
                        tracks[r.index].deezerDuration = r.deezerDuration
                        tracks[r.index].deezerAlbum = r.deezerAlbum
                    } else {
                        tracks[r.index].title = "Unavailable track"
                        tracks[r.index].status = .failed(r.message ?? "Spotify lookup failed")
                    }
                    if ids.count > 1 {
                        progress = "Resolving \(r.index + 1)/\(ids.count)…"
                    }
                }
            }
        }
    }

    /// Phase B for one row: memo → disk match → full search/score/MB pipeline.
    /// Indices stay valid: rows are only appended in Phase A, never removed here.
    private func matchRow(at idx: Int, id: String) async {
        guard tracks.indices.contains(idx) else { return }
        // Already resolved, or Tier-1 failed with nothing to search.
        // (Retry paths reset to .working first.)
        if case .matched = tracks[idx].status { return }
        if case .failed = tracks[idx].status { return }
        matchingStartedAt[id] = Date()

        // Session memo: same recording, same answer.
        if let m = memo[id] {
            applyMatch(idx: idx, score: m.score, youtubeID: m.youtubeID,
                       youtubeTitle: m.youtubeTitle, duration: m.duration,
                       exact: m.exact)
            return
        }
        // Disk match cache (30d): skips re-searching across launches.
        if let c = diskMatches?[id],
           Date().timeIntervalSince(c.at) < YouTubeMatcher.matchCacheTTL {
            let m = Memo(title: tracks[idx].title, artist: tracks[idx].artist,
                         artworkURL: tracks[idx].artworkURL, score: c.score,
                         youtubeID: c.youtubeID, youtubeTitle: c.youtubeTitle,
                         duration: c.duration, exact: c.exact)
            memo[id] = m
            applyMatch(idx: idx, score: m.score, youtubeID: m.youtubeID,
                       youtubeTitle: m.youtubeTitle, duration: m.duration,
                       exact: m.exact)
            return
        }

        do {
            try Task.checkCancellation()
            let query = YouTubeMatcher.query(artist: tracks[idx].artist,
                                             title: tracks[idx].title)
            let candidates = try await service.searchYouTube(
                query: query.isEmpty ? tracks[idx].title : query)
            let anchor = tracks[idx].deezerDuration
            var best: (entry: PlaylistEntry, score: Double)?
            var runnerUp: Double?
            for c in candidates {
                let s = YouTubeMatcher.score(
                    artist: tracks[idx].artist, title: tracks[idx].title,
                    anchorDuration: anchor, candidate: c)
                if best == nil || s > best!.score {
                    runnerUp = best?.score
                    best = (c, s)
                } else if runnerUp == nil || s > runnerUp! {
                    runnerUp = s
                }
            }

            guard let best else {
                tracks[idx].status = .failed("No YouTube match")
                return
            }
            // Paint immediately: the badge is visible the moment scoring lands.
            // MusicBrainz below only ever upgrades (exact/rescored) from here.
            applyMatch(idx: idx, score: best.score, youtubeID: best.entry.id,
                       youtubeTitle: best.entry.safeTitle,
                       duration: best.entry.duration, exact: false)
            let preSelect = tracks[idx].selected

            // Tier 3 (ambiguous only, opt-in): MusicBrainz duration re-score +
            // curated URLs. OFF by default — each consultation costs 2+ paced
            // requests. Clear winners skip MB entirely even when enabled.
            guard Self.confidenceCheckEnabled,
                  YouTubeMatcher.needsAdjudication(best: best.score, runnerUp: runnerUp) else {
                recordMatch(idx: idx, id: id, score: best.score,
                            youtubeID: best.entry.id,
                            youtubeTitle: best.entry.safeTitle,
                            duration: best.entry.duration, exact: false)
                return
            }
            try Task.checkCancellation()
            var exact = false
            var final = best
            if let mb = await MusicBrainzClient.searchRecording(
                artist: tracks[idx].artist, title: tracks[idx].title) {
                let rels = await MusicBrainzClient.youtubeURLs(mbid: mb.id)
                let exactIDs = YouTubeMatcher.exactMatchIDs(mbURLs: rels, candidates: candidates)
                if let hit = candidates.first(where: { exactIDs.contains($0.id) }) {
                    final = (hit, 1.0)
                    exact = true
                } else if let mbLen = mb.lengthSeconds {
                    let rescored = YouTubeMatcher.score(
                        artist: tracks[idx].artist, title: tracks[idx].title,
                        anchorDuration: mbLen, candidate: best.entry)
                    final = (best.entry, max(best.score, rescored))
                }
            }

            recordMatch(idx: idx, id: id, score: final.score,
                        youtubeID: final.entry.id,
                        youtubeTitle: final.entry.safeTitle,
                        duration: final.entry.duration, exact: exact)
            // Preserve a manual tick/untick made while MB was resolving:
            // recordMatch recomputes selection from score, so restore a choice
            // that differs from the recomputed value.
            let autoValue = final.score >= YouTubeMatcher.autoSelectThreshold || exact
            if tracks.indices.contains(idx), tracks[idx].selected == autoValue,
               preSelect != autoValue {
                tracks[idx].selected = preSelect
            }
        } catch is CancellationError {
            tracks[idx].status = .failed("Cancelled")
        } catch {
            tracks[idx].status = .failed(Task.isCancelled ? "Cancelled" : error.localizedDescription)
        }
    }

    /// Writes a match to row + session memo + disk cache.
    private func recordMatch(idx: Int, id: String, score: Double, youtubeID: String,
                             youtubeTitle: String, duration: Double?, exact: Bool) {
        memo[id] = Memo(title: tracks[idx].title, artist: tracks[idx].artist,
                        artworkURL: tracks[idx].artworkURL, score: score,
                        youtubeID: youtubeID, youtubeTitle: youtubeTitle,
                        duration: duration, exact: exact)
        var cache = diskMatches ?? [:]
        cache[id] = CachedMatch(youtubeID: youtubeID, score: score,
                                youtubeTitle: youtubeTitle, duration: duration,
                                exact: exact)
        diskMatches = cache
        YouTubeMatcher.writeMatchCache(cache)
        applyMatch(idx: idx, score: score, youtubeID: youtubeID,
                   youtubeTitle: youtubeTitle, duration: duration, exact: exact)
    }

    private func applyMatch(idx: Int, score: Double, youtubeID: String,
                            youtubeTitle: String, duration: Double?, exact: Bool) {
        guard tracks.indices.contains(idx) else { return }
        matchingStartedAt.removeValue(forKey: tracks[idx].id)
        tracks[idx].status = .matched(score: score, youtubeID: youtubeID,
                                      youtubeTitle: youtubeTitle,
                                      duration: duration, exact: exact)
        tracks[idx].selected = score >= YouTubeMatcher.autoSelectThreshold || exact
    }

    // MARK: - Retry

    /// Re-runs matching for one failed row (resets it first).
    func retryTrack(id: String) async {
        guard let idx = tracks.firstIndex(where: { $0.id == id }),
              !isImporting else { return }
        importTask?.cancel()
        await service.cancelProbes()
        let session = UUID()
        importSession = session
        isImporting = true
        progress = "Retrying…"
        defer { if importSession == session { isImporting = false }; progress = nil }
        let task = Task {
            tracks[idx].status = .working
            tracks[idx].selected = false
            matchingStartedAt[id] = Date()
            matchProgressState = nil
            await matchRow(at: idx, id: id)
        }
        importTask = task
        await task.value
        if importSession == session { importTask = nil }
    }

    /// Re-runs matching for every failed row, serially.
    func retryFailed() async {
        let ids = tracks.filter {
            if case .failed = $0.status { return true }
            return false
        }.map(\.id)
        guard !ids.isEmpty, !isImporting else { return }
        importTask?.cancel()
        await service.cancelProbes()
        let session = UUID()
        importSession = session
        isImporting = true
        defer { if importSession == session { isImporting = false }; progress = nil }
        let task = Task {
            var done = 0
            for id in ids {
                if Task.isCancelled { return }
                guard self.importSession == session else { return }
                if ids.count > 1 { self.progress = "Retrying \(done + 1)/\(ids.count)…" }
                if let idx = self.tracks.firstIndex(where: { $0.id == id }) {
                    self.tracks[idx].status = .working
                    self.tracks[idx].selected = false
                    await self.matchRow(at: idx, id: id)
                }
                done += 1
            }
        }
        importTask = task
        await task.value
        if importSession == session { importTask = nil }
    }

    // MARK: - Handoff to New Batch drafts

    /// Appends selected matches to the download drafts (Spotify-sourced tags,
    /// playlist name as album) and returns how many were added.
    @discardableResult
    func addSelectedToBatch(_ store: DownloadStore) -> Int {
        // Only matched rows are addable — Select-all no longer ticks
        // .working/.failed, but filter defensively so the count returned
        // always equals the rows actually appended.
        let matchedPicked = tracks.filter { $0.selected && $0.isMatched }
        guard !matchedPicked.isEmpty else { return 0 }
        let wasEmpty = store.draftJobs.isEmpty
        var added = 0
        for t in matchedPicked {
            guard case .matched(_, let youtubeID, _, let duration, _) = t.status else { continue }
            let album = playlistTitle ?? t.deezerAlbum
            let tags = TagParser.parse(
                title: t.title, uploader: t.artist,
                playlistTitle: album, playlistIndex: album != nil ? added + 1 : nil,
                uploadDate: nil)
            store.draftJobs.append(DownloadJob(
                url: "https://www.youtube.com/watch?v=\(youtubeID)",
                kind: store.batchMode,
                displayTitle: t.title,
                thumbnailURL: t.artworkURL,
                duration: duration,
                artworkURL: t.artworkURL,
                audioFormat: store.batchFormat,
                videoQuality: store.videoQuality,
                tags: tags))
            added += 1
        }
        if wasEmpty {
            store.probeTitle = playlistTitle ?? matchedPicked.first?.title
        }
        if added > 0 {
            NotificationCenter.default.post(name: .beatStashShowNewBatch, object: nil)
        }
        return added
    }
}
