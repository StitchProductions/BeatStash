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
        case resolved
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

    public var isResolved: Bool {
        if case .resolved = status { return true }
        return false
    }
}

/// Spotify → YouTube import: playlist/track links in, resolvable drafts out.
///
/// Pipeline: Spotify oEmbed metadata (~0.2s) + Deezer anchor (~0.3s),
/// 4-wide parallel. Rows resolve in seconds; there is no per-track YouTube
/// search here by design (that serial ~13s/track crawl was the whole import).
/// Handoff emits `ytsearch1:artist title` draft URLs and New Batch resolves
/// each to the first YouTube result at fetch time — first result wins, no
/// scoring, no confidence badges. Review drafts by eye before downloading.
/// Nothing downloads from here.
@Observable
final class SpotifyImportStore {
    var urlText: String = ""
    var isImporting = false
    var progress: String?
    var errorMessage: String?
    var playlistTitle: String?
    var tracks: [SpotifyImportTrack] = []

    private var importTask: Task<Void, Never>?
    private var importSession: UUID?
    private let service = YTDLPService()

    var resolvedCount: Int {
        tracks.filter { if case .resolved = $0.status { true } else { false } }.count
    }

    var failedCount: Int {
        tracks.filter { if case .failed = $0.status { true } else { false } }.count
    }

    var selectedCount: Int {
        tracks.filter { $0.selected }.count
    }

    /// Selected rows that are actually addable (resolved). The Add button
    /// promises this count — `selectedCount` can include .working/.failed
    /// rows when Select-all ran mid-import, which handoff must skip.
    var selectedResolvedCount: Int {
        tracks.filter { $0.selected && $0.isResolved }.count
    }

    /// Add is only available once resolving has settled (prevents the
    /// "button said 50, New Batch got 1" trap from adding mid-import).
    var canAddToBatch: Bool {
        !isImporting && selectedResolvedCount > 0
    }

    /// Select-all state over addable rows only (per-row toggles are
    /// disabled for non-resolved, so Select-all must not tick them either).
    var allSelectableSelected: Bool {
        let selectable = tracks.filter { $0.isResolved }
        return !selectable.isEmpty && selectable.allSatisfy { $0.selected }
    }

    func setAllSelectable(_ v: Bool) {
        for i in tracks.indices where tracks[i].isResolved {
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
        if isImporting { isImporting = false }
    }

    /// Clears imported tracks (Clear all button). The pasted link stays so
    /// the import can be edited and re-run. Any in-flight import is
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
        playlistTitle = nil
        progress = "Reading Spotify…"
        defer {
            if importSession == session { isImporting = false }
            progress = nil
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
            // Rows + metadata (4-wide chunks — cheap surfaces). No YouTube
            // search here: handoff emits `ytsearch1:` URLs that New Batch
            // resolves to first results at fetch time.
            for trackID in ids {
                tracks.append(SpotifyImportTrack(id: trackID))
            }
            try await resolveTier1Chunked(ids: ids)
        } catch is CancellationError {
            guard importSession == session else { return }
            errorMessage = nil
        } catch {
            guard importSession == session else { return }
            errorMessage = Task.isCancelled ? nil : error.localizedDescription
        }
    }

    /// Metadata + Deezer anchors for every row, 4 at a time. Cheap
    /// official-API GETs on distinct hosts — safe to parallelize. Rows are
    /// pre-created, so the list keeps playlist order. Resolved rows are
    /// selected by default; per-track misses mark their row failed.
    /// Throws only on cancellation.
    private nonisolated struct Tier1: Sendable {
        var index: Int
        var title: String?
        var artist: String?
        var artworkURL: String?
        var deezerDuration: Double?
        var deezerAlbum: String?
        var message: String?
    }

    /// One row's Spotify + Deezer lookup. Shared by the chunked import and
    /// single-row retry. Never throws except on cancellation; misses come
    /// back as a message-carrying `Tier1`.
    private nonisolated static func fetchTier1(id: String, index: Int) async throws -> Tier1 {
        try Task.checkCancellation()
        do {
            let meta = try await SpotifyService.fetchTrackMeta(id: id)
            let deezer = await DeezerClient.search(
                artist: meta.artist, title: meta.title)
            return Tier1(
                index: index, title: meta.title,
                artist: meta.artist.isEmpty
                    ? (deezer?.artistName ?? "") : meta.artist,
                artworkURL: meta.artworkURL,
                deezerDuration: deezer?.duration.map(Double.init),
                deezerAlbum: deezer?.albumName,
                message: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Tier1(index: index, title: nil, artist: nil,
                         artworkURL: nil, deezerDuration: nil,
                         deezerAlbum: nil,
                         message: error.localizedDescription)
        }
    }

    /// Paints a fetched `Tier1` onto its row: resolved + selected on success,
    /// failed otherwise. Indices stay valid — rows are only appended up front.
    private func applyTier1(_ r: Tier1) {
        guard tracks.indices.contains(r.index) else { return }
        if let title = r.title {
            tracks[r.index].title = title
            tracks[r.index].artist = r.artist ?? ""
            tracks[r.index].artworkURL = r.artworkURL
            tracks[r.index].deezerDuration = r.deezerDuration
            tracks[r.index].deezerAlbum = r.deezerAlbum
            tracks[r.index].status = .resolved
            tracks[r.index].selected = true
        } else {
            tracks[r.index].title = "Unavailable track"
            tracks[r.index].status = .failed(r.message ?? "Spotify lookup failed")
        }
    }

    private func resolveTier1Chunked(ids: [String]) async throws {
        for start in stride(from: 0, to: ids.count, by: 4) {
            try Task.checkCancellation()
            let end = min(start + 4, ids.count)
            try await withThrowingTaskGroup(of: Tier1.self) { group in
                for idx in start..<end {
                    let id = ids[idx]
                    group.addTask {
                        try await Self.fetchTier1(id: id, index: idx)
                    }
                }
                for try await r in group {
                    applyTier1(r)
                    if ids.count > 1 {
                        progress = "Resolving \(r.index + 1)/\(ids.count)…"
                    }
                }
            }
        }
    }

    /// Single-row resolve for retry: resets the row first.
    private func resolveTier1Row(at idx: Int, id: String) async {
        guard tracks.indices.contains(idx) else { return }
        tracks[idx].status = .working
        tracks[idx].selected = false
        do {
            applyTier1(try await Self.fetchTier1(id: id, index: idx))
        } catch is CancellationError {
            tracks[idx].status = .failed("Cancelled")
        } catch {
            tracks[idx].status = .failed(Task.isCancelled ? "Cancelled" : error.localizedDescription)
        }
    }

    // MARK: - Retry

    /// Re-resolves one failed row's Spotify metadata (resets it first).
    /// Cheap Tier-1 lookup only — there is no matching pass anymore.
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
            await resolveTier1Row(at: idx, id: id)
        }
        importTask = task
        await task.value
        if importSession == session { importTask = nil }
    }

    /// Re-resolves every failed row's Spotify metadata, serially.
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
                    await self.resolveTier1Row(at: idx, id: id)
                }
                done += 1
            }
        }
        importTask = task
        await task.value
        if importSession == session { importTask = nil }
    }

    // MARK: - Handoff to New Batch drafts

    /// `ytsearch1:` query URL for a resolved row. New Batch probes it like
    /// any other URL and lands on the first YouTube result — first result
    /// wins by design (no scoring here).
    nonisolated static func searchURL(artist: String, title: String) -> String {
        let q = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        return "ytsearch1:\(q.isEmpty ? title : q)"
    }

    /// Appends selected resolved rows to the download drafts
    /// (Spotify-sourced tags, playlist name as album) and returns how many
    /// were added. Draft durations come from the Deezer anchor; anything
    /// missing shows "–" until New Batch fetch enriches it.
    @discardableResult
    func addSelectedToBatch(_ store: DownloadStore) -> Int {
        // Only resolved rows are addable — Select-all no longer ticks
        // .working/.failed, but filter defensively so the count returned
        // always equals the rows actually appended.
        let picked = tracks.filter { $0.selected && $0.isResolved }
        guard !picked.isEmpty else { return 0 }
        let wasEmpty = store.draftJobs.isEmpty
        var added = 0
        for t in picked {
            guard case .resolved = t.status else { continue }
            let album = playlistTitle ?? t.deezerAlbum
            let tags = TagParser.parse(
                title: t.title, uploader: t.artist,
                playlistTitle: album, playlistIndex: album != nil ? added + 1 : nil,
                uploadDate: nil)
            store.draftJobs.append(DownloadJob(
                url: Self.searchURL(artist: t.artist, title: t.title),
                kind: store.batchMode,
                displayTitle: t.title,
                thumbnailURL: t.artworkURL,
                duration: t.deezerDuration,
                artworkURL: t.artworkURL,
                audioFormat: store.batchFormat,
                videoQuality: store.videoQuality,
                tags: tags))
            added += 1
        }
        if wasEmpty {
            store.probeTitle = playlistTitle ?? picked.first?.title
        }
        if added > 0 {
            NotificationCenter.default.post(name: .beatStashShowNewBatch, object: nil)
        }
        return added
    }
}
