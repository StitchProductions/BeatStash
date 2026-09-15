import Foundation
import Testing
@testable import BeatStash

/// Draft-list lifecycle: Clear list removes fetch results but keeps input.
@MainActor
struct DownloadStoreTests {
    private func storeWithDrafts() -> DownloadStore {
        let store = DownloadStore()
        store.urlText = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        store.draftJobs = [
            DownloadJob(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                        displayTitle: "T",
                        tags: TrackTags(artist: "A", title: "T")),
        ]
        store.probeTitle = "Some Title"
        store.fetchError = "stale error"
        return store
    }

    @Test func clearDraftsResetsResultsKeepsInput() {
        let store = storeWithDrafts()
        let queueBefore = store.queue.map(\.id)
        store.clearDrafts()
        #expect(store.draftJobs.isEmpty)
        #expect(store.probeTitle == nil)
        #expect(store.fetchError == nil)
        #expect(store.fetchProgress == nil)
        #expect(!store.isFetching)
        // Pasted links stay so the batch can be edited and re-fetched;
        // the queue is never touched by a drafts clear.
        #expect(store.urlText == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(store.queue.map(\.id) == queueBefore)
    }

    @Test func clearDraftsOnEmptyStateIsNoop() {
        let store = DownloadStore()
        store.clearDrafts()
        #expect(store.draftJobs.isEmpty)
        #expect(store.probeTitle == nil)
        #expect(store.fetchError == nil)
    }

    // MARK: - Queue durability (quit/crash survival)

    private func queuedJob(_ title: String, status: JobStatus) -> DownloadJob {
        var job = DownloadJob(url: "https://www.youtube.com/watch?v=\(title)",
                              displayTitle: title,
                              tags: TrackTags(artist: "A", title: title))
        job.status = status
        return job
    }

    @Test func restoredStatusMapping() {
        // Interrupted work and failed rows requeue…
        for s: JobStatus in [.downloading, .tagging, .fetching, .failed] {
            #expect(DownloadStore.restoredStatus(for: s) == .queued, "\(s)")
        }
        // …already-queued rows just need pump, cancelled/completed/waiting
        // rows stay put.
        for s: JobStatus in [.pending, .queued, .cancelled, .completed] {
            #expect(DownloadStore.restoredStatus(for: s) == nil, "\(s)")
        }
    }

    @Test func queueDecodeRejectsGarbage() {
        // Corrupt input and unknown versions fail soft (empty relaunch,
        // never a launch crash).
        #expect(DownloadStore.decodeQueue(from: Data("not json".utf8)) == nil)
        #expect(DownloadStore.decodeQueue(from: Data("{\"version\":99,\"jobs\":[]}".utf8)) == nil)
        #expect(DownloadStore.decodeQueue(from: Data("{\"version\":1,\"jobs\":[]}".utf8))?.isEmpty == true)
        // Wrong-typed or keyless jobs fail the whole envelope soft, too.
        #expect(DownloadStore.decodeQueue(from: Data("{\"version\":1,\"jobs\":\"nope\"}".utf8)) == nil)
        #expect(DownloadStore.decodeQueue(from: Data("{\"version\":1,\"jobs\":[{}]}".utf8)) == nil)
    }

    private func isolatedStoreFiles() throws -> (queue: URL, history: URL) {
        let dir = try TestHelpers.makeTempDir()
        return (dir.appendingPathComponent("queue.json"),
                dir.appendingPathComponent("history.json"))
    }

    private func isolateStores() throws -> URL {
        // Redirects both persisted files so tests never touch the real
        // Application Support data. Returns the temp dir for cleanup.
        let files = try isolatedStoreFiles()
        DownloadStore.queueFileOverride = files.queue
        DownloadStore.historyFileOverride = files.history
        return files.queue.deletingLastPathComponent()
    }

    @Test func queueFileRoundTrip() throws {
        let dir = try isolateStores()
        defer {
            DownloadStore.queueFileOverride = nil
            DownloadStore.historyFileOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        var done = queuedJob("Done", status: .completed)
        done.progress = 1
        done.outputPath = "/Music/01 - Done [d].m4a"
        var failed = queuedJob("Bad", status: .failed)
        failed.errorMessage = "boom"
        let store = DownloadStore()
        store.queue = [done, failed]
        store.clearFinished() // persists queue + moves completed to history
        #expect(store.queue.isEmpty)
        #expect(store.history.first?.title == "Done")
        // A fresh launch reads back exactly what was persisted.
        let relaunched = DownloadStore()
        #expect(relaunched.queue.isEmpty)
        #expect(relaunched.history.first?.title == "Done")
        // Load sanitizes live progress but keeps settled state.
        let store2 = DownloadStore()
        var active = queuedJob("Mid", status: .downloading)
        active.progress = 0.5
        active.phaseLabel = "Converting audio…"
        active.speedString = "1MiB/s"
        store2.queue = [active]
        store2.clearFinished() // nothing finished: persists queue as-is
        let relaunched2 = DownloadStore()
        #expect(relaunched2.queue.count == 1)
        #expect(relaunched2.queue.first?.status == .downloading)
        #expect(relaunched2.queue.first?.progress == 0)
        #expect(relaunched2.queue.first?.phaseLabel == nil)
    }

    @Test func normalizeQueueForResumeMapping() throws {
        let dir = try isolateStores()
        defer {
            DownloadStore.queueFileOverride = nil
            DownloadStore.historyFileOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let store = DownloadStore()
        store.queue = [
            queuedJob("Q", status: .queued),
            queuedJob("D", status: .downloading),
            queuedJob("F", status: .failed),
            queuedJob("C", status: .cancelled),
            queuedJob("Done", status: .completed),
        ]
        #expect(store.normalizeQueueForResume())
        let statuses = Dictionary(uniqueKeysWithValues: store.queue.map { ($0.displayTitle, $0.status) })
        #expect(statuses["Q"] == .queued)
        #expect(statuses["D"] == .queued)
        #expect(statuses["F"] == .queued)
        #expect(statuses["C"] == .cancelled)
        #expect(statuses["Done"] == .completed)
        // Failed rows lose their stale message for the fresh attempt.
        #expect(store.queue.first(where: { $0.displayTitle == "F" })?.errorMessage == nil)
        // Idempotent: a second pass finds nothing requeueable (and crucially
        // never pumps, so this test spawns no downloads).
        #expect(!store.normalizeQueueForResume())
    }

    @Test func clearFinishedMovesCompletedToHistoryDropsFailed() throws {
        let dir = try isolateStores()
        defer {
            DownloadStore.queueFileOverride = nil
            DownloadStore.historyFileOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let store = DownloadStore()
        store.history = []
        var first = queuedJob("First", status: .completed)
        first.outputPath = "/Music/01 - First [a].m4a"
        var second = queuedJob("Second", status: .completed)
        second.outputPath = "/Music/02 - Second [b].m4a"
        store.queue = [first, second, queuedJob("Bad", status: .failed)]
        store.clearFinished()
        #expect(store.queue.isEmpty)
        // Newest completion on top, matching completion-time ordering.
        #expect(store.history.map(\.title) == ["Second", "First"])
        #expect(!store.history.map(\.title).contains("Bad"))
    }

    @Test func searchURLJobSurvivesRelaunch() throws {
        let dir = try isolateStores()
        defer {
            DownloadStore.queueFileOverride = nil
            DownloadStore.historyFileOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        // Spotify handoff drafts carry ytsearch1: URLs — the queue must
        // persist them verbatim for New Batch to resolve at fetch time.
        var job = queuedJob("Hello", status: .queued)
        job.url = "ytsearch1:Adele Hello"
        job.audioFormat = .mp3
        let store = DownloadStore()
        store.queue = [job]
        store.clearFinished() // nothing finished: persists queue as-is
        let relaunched = DownloadStore()
        #expect(relaunched.queue.count == 1)
        #expect(relaunched.queue.first?.url == "ytsearch1:Adele Hello")
        #expect(relaunched.queue.first?.status == .queued)
        #expect(relaunched.queue.first?.audioFormat == .mp3)
    }

    @Test func relaunchMidRetryRequeuesClean() throws {
        let dir = try isolateStores()
        defer {
            DownloadStore.queueFileOverride = nil
            DownloadStore.historyFileOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        // Killed mid auto-retry: live progress + the attempt note on disk.
        var retrying = queuedJob("Retry", status: .downloading)
        retrying.progress = 0.4
        retrying.phaseLabel = "Preparing…"
        retrying.speedString = "1MiB/s"
        retrying.errorMessage = "Auto-retrying (attempt 2/3)…"
        let store = DownloadStore()
        store.queue = [retrying]
        store.clearFinished() // persists queue as-is
        // Fresh launch: load sanitizes live state, resume requeues fresh.
        // (normalize never pumps, so this spawns no downloads.)
        let relaunched = DownloadStore()
        #expect(relaunched.queue.first?.progress == 0)
        #expect(relaunched.queue.first?.phaseLabel == nil)
        #expect(relaunched.normalizeQueueForResume())
        #expect(relaunched.queue.first?.status == .queued)
        #expect(relaunched.queue.first?.errorMessage == nil)
    }
}
