import Foundation
import Testing
@testable import BeatStash

/// Error classification is the backbone of chain fallback + user messages.
/// Every sample below is a real yt-dlp stderr shape.
@MainActor
struct ProbeErrorTests {
    @Test func botCheck() {
        let e = YTDLPService.classifyProbeError(
            stderr: "ERROR: [youtube] x: Sign in to confirm you're not a bot.")
        if case .botCheck = e {} else { Issue.record("expected botCheck") }
    }

    @Test func apiPage403IsBotWall() {
        let e = YTDLPService.classifyProbeError(
            stderr: "ERROR: Unable to download API page: HTTP Error 403 (Forbidden)")
        if case .botCheck = e {} else { Issue.record("expected botCheck") }
    }

    @Test func loginRequired() {
        let e = YTDLPService.classifyProbeError(stderr: "ERROR: Private video. Login required.")
        if case .loginRequired = e {} else { Issue.record("expected loginRequired") }
    }

    @Test func videoUnavailable() {
        let e = YTDLPService.classifyProbeError(stderr: "ERROR: Video unavailable. This video has been deleted.")
        if case .videoUnavailable = e {} else { Issue.record("expected videoUnavailable") }
    }

    @Test func reloadRequired() {
        let e = YTDLPService.classifyProbeError(stderr: "ERROR: [youtube] x: This page needs to be reloaded.")
        if case .reloadRequired = e {} else { Issue.record("expected reloadRequired") }
    }

    @Test func formatGated() {
        let e = YTDLPService.classifyProbeError(
            stderr: "ERROR: [youtube] x: Requested format is not available.")
        if case .formatGated = e {} else { Issue.record("expected formatGated") }
    }

    @Test func networkError() {
        let e = YTDLPService.classifyProbeError(stderr: "ERROR: [youtube] x: Timed out.")
        if case .networkError = e {} else { Issue.record("expected networkError") }
    }

    @Test func unknownFallsBackToDownloadFailed() {
        let e = YTDLPService.classifyProbeError(stderr: "ERROR: something brand new")
        if case .downloadFailed(let m) = e {
            #expect(m.contains("something brand new"))
        } else {
            Issue.record("expected downloadFailed")
        }
    }

    @Test func allProbeErrorsRetryAcrossChains() {
        // Chains differ in trust, so every failure is worth one more attempt.
        for e: YTDLPService.ServiceError in [
            .probeTimeout(1), .clientFailed("x"), .reloadRequired("x"),
            .formatGated("x"), .networkError("x"), .downloadFailed("x"),
            .botCheck("x"), .loginRequired("x"), .videoUnavailable("x"),
            .parseFailed("x"), .missingBinary, .outputNotFound,
        ] {
            #expect(YTDLPService.isRetryableProbeError(e))
        }
    }

    @Test func decodeMediaToleratesLeadingWarnings() {
        let blob = """
            WARNING: [youtube] PO Token vague warning
            {"id":"abc","title":"T","duration":12}
            """
        #expect(YTDLPService.decodeMedia(from: blob)?.id == "abc")
    }

    @Test func decodeMediaRejectsGarbage() {
        #expect(YTDLPService.decodeMedia(from: "nope\nstill nope\n") == nil)
    }

    @Test func parseProgressLine() {
        let p = YTDLPService.parseProgress(
            line: "[download]  42.3% of ~5.12MiB at 2.10MiB/s ETA 00:02")
        #expect(abs((p?.fraction ?? -1) - 0.423) < 0.001)
        #expect(p?.speed == "2.10MiB/s")
        #expect(p?.eta == "00:02")
    }

    @Test func parseProgressRejectsNonDownloadLines() {
        #expect(YTDLPService.parseProgress(line: "[info] hello") == nil)
        #expect(YTDLPService.parseProgress(line: "[download] Destination: x.mp4") == nil)
    }

    @Test func downloadPhaseLabels() {
        #expect(YTDLPService.phaseFor(line: "[ExtractAudio] Destination: x.m4a") == "Converting audio…")
        #expect(YTDLPService.phaseFor(line: "[EmbedThumbnail] mutagen") == "Embedding cover…")
        #expect(YTDLPService.phaseFor(line: "[ThumbnailsConvert] Converting") == "Converting cover…")
        #expect(YTDLPService.phaseFor(line: "[Metadata] Adding metadata") == "Writing metadata…")
        #expect(YTDLPService.phaseFor(line: "[Merger] Merging formats") == "Merging formats…")
        #expect(YTDLPService.phaseFor(line: "[VideoConvertor] Converting") == "Converting video…")
        #expect(YTDLPService.phaseFor(line: "[download] Destination: x.mp4") == "Starting download…")
        #expect(YTDLPService.phaseFor(line: "[download]  42.3% of ~5MiB at 2MiB/s ETA 00:02") == nil)
        #expect(YTDLPService.phaseFor(line: "[info] hello") == nil)
    }

    @Test func pipeChunkSplitCarriesRemainder() {
        let (lines, rest) = YTDLPService.appendLines(buffer: "", chunk: "[downlo")
        #expect(lines.isEmpty && rest == "[downlo")
        let (lines2, rest2) = YTDLPService.appendLines(buffer: rest, chunk: "ad]  10% done\n[downlo")
        #expect(lines2 == ["[download]  10% done"] && rest2 == "[downlo")
        let (lines3, rest3) = YTDLPService.appendLines(buffer: rest2, chunk: "ad] done\n")
        #expect(lines3 == ["[download] done"] && rest3.isEmpty)
    }

    @Test func extractionGateSerializes() async throws {
        let gate = AsyncSemaphore(limit: 1)
        try await gate.acquire()
        let started = LockedFlag()
        let entered = LockedFlag()
        let waiter = Task {
            started.set()
            try? await gate.acquire()
            entered.set()
            gate.release()
        }
        // Wait until the waiter is provably parked on acquire (deadline, not
        // a blind sleep — on loaded CI the task may start late, which used
        // to make the assertion vacuous).
        let deadline = Date().addingTimeInterval(5)
        while !started.value, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(started.value) // waiter running; a timeout here is the failure
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!entered.value) // second acquirer blocks while held
        gate.release()
        await waiter.value
        #expect(entered.value)
    }

    @Test func extractionGateCancelWhileParkedFreesSlot() async throws {
        enum GateTimeout: Error { case timedOut }
        let gate = AsyncSemaphore(limit: 1)
        try await gate.acquire() // hold the only permit
        let parked = Task { try await gate.acquire() }
        try? await Task.sleep(nanoseconds: 100_000_000) // let it park
        parked.cancel()
        let outcome = await parked.result
        guard case .failure(let e) = outcome, e is CancellationError else {
            Issue.record("parked acquire should throw CancellationError")
            return
        }
        gate.release() // free the held permit
        // Must succeed promptly: a leaked waiter would eat this release and hang.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await gate.acquire() }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw GateTimeout.timedOut
            }
            try await group.next()
            group.cancelAll()
        }
        gate.release()
    }

    @Test func probeArgsIgnoreMissingFormats() async {
        // Worst-case insurance: format-gated videos succeed on chain 0 with
        // metadata instead of burning every fallback. Probe-only — downloads
        // must still fail loudly without usable formats.
        let args = YTDLPService.probeBaseArgs(auth: YouTubeAuth(), chain: ["android", "ios", "tv"])
        #expect(args.contains("--ignore-no-formats-error"))
        let downloadArgs = await YTDLPService().buildArguments(
            job: DownloadJob(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                             kind: .audio, displayTitle: "T", tags: TrackTags()),
            directory: URL(fileURLWithPath: "/tmp"))
        #expect(!downloadArgs.contains("--ignore-no-formats-error"))
    }

    @Test func wavPhaseWarnsAboutStall() {
        #expect(YTDLPService.phaseFor(line: "[ExtractAudio] Destination: track.wav") ==
            "Saving WAV… large file, may sit at 100% a while")
        // Non-WAV extraction labels are unchanged.
        #expect(YTDLPService.phaseFor(line: "[ExtractAudio] Destination: x.m4a") == "Converting audio…")
    }

    @Test func preparingPhasePlainLanguage() {
        // Single chain: bare label, no jargon, no option numbers.
        #expect(YTDLPService.preparingPhase(attempt: 1, total: 1, lastError: nil, elapsed: 0) == "Preparing…")
        // First of many: option number, no blame yet.
        #expect(YTDLPService.preparingPhase(attempt: 1, total: 4, lastError: nil, elapsed: 0) == "Preparing…")
        // Retry carries the previous failure's reason — never a client name.
        let p = YTDLPService.preparingPhase(
            attempt: 2, total: 4,
            lastError: YTDLPService.ServiceError.formatGated("x"), elapsed: 0)
        #expect(p.contains("trying option 2/4"))
        #expect(p.contains("had no audio formats"))
        #expect(!p.contains("android") && !p.contains("client"))
        // Elapsed ticks only once the stall is real (≥2s).
        let slow = YTDLPService.preparingPhase(attempt: 2, total: 4, lastError: nil, elapsed: 12)
        #expect(slow.contains("12s"))
        let fast = YTDLPService.preparingPhase(attempt: 1, total: 4, lastError: nil, elapsed: 0)
        #expect(!fast.contains("0s"))
    }

    @Test func shortReasonHasNoJargon() {
        #expect(YTDLPService.shortReason(for: YTDLPService.ServiceError.formatGated("x")) == "had no audio formats")
        #expect(YTDLPService.shortReason(for: YTDLPService.ServiceError.reloadRequired("x")) == "rejected the request")
        #expect(YTDLPService.shortReason(for: YTDLPService.ServiceError.botCheck("x")) == "asked for a sign-in check")
        #expect(YTDLPService.shortReason(for: YTDLPService.ServiceError.networkError("x")) == "hit a network error")
        #expect(YTDLPService.shortReason(for: YTDLPService.ServiceError.probeTimeout(30)) == "timed out")
        for e: YTDLPService.ServiceError in [
            .formatGated("x"), .reloadRequired("x"), .botCheck("x"),
            .loginRequired("x"), .networkError("x"), .probeTimeout(1),
            .thumbnailUnsupported("x"),
        ] {
            #expect(!YTDLPService.shortReason(for: e).contains("android"))
            #expect(!YTDLPService.shortReason(for: e).contains("player_client"))
        }
    }

    @Test func strippingElapsedSuffixIdempotent() {
        #expect(YTDLPService.strippingElapsedSuffix("Preparing…") == "Preparing…")
        #expect(YTDLPService.strippingElapsedSuffix("Preparing… · 12s") == "Preparing…")
        #expect(YTDLPService.strippingElapsedSuffix("Preparing… trying option 2/4 · 7s") ==
            "Preparing… trying option 2/4")
    }

    @Test func printedFilePathParsing() {
        #expect(YTDLPService.parsePrintedFilePath(line: "/Music/01 - Title [abc].m4a") ==
            "/Music/01 - Title [abc].m4a")
        #expect(YTDLPService.parsePrintedFilePath(line: "[download]  42.3% of ~5MiB at 2MiB/s ETA 00:02") == nil)
        #expect(YTDLPService.parsePrintedFilePath(line: "[info] hello") == nil)
        #expect(YTDLPService.parsePrintedFilePath(line: "[ExtractAudio] Destination: x.m4a") == nil)
        #expect(YTDLPService.parsePrintedFilePath(line: "") == nil)
    }

    @Test func probeKeyNormalization() {
        // Volatile share params must not bust the probe cache into a re-probe.
        let a = YTDLPService.normalizedProbeKey("https://www.youtube.com/watch?v=abc123&si=XYZ&feature=shared")
        let b = YTDLPService.normalizedProbeKey("https://www.youtube.com/watch?v=abc123")
        #expect(a == b)
        // Param order is irrelevant; identity params are kept.
        let c = YTDLPService.normalizedProbeKey("https://www.youtube.com/watch?list=PL1&v=abc123")
        let d = YTDLPService.normalizedProbeKey("https://www.youtube.com/watch?v=abc123&list=PL1")
        #expect(c == d)
        // Different videos still differ; non-YouTube passes through.
        #expect(YTDLPService.normalizedProbeKey("https://www.youtube.com/watch?v=aaa") !=
            YTDLPService.normalizedProbeKey("https://www.youtube.com/watch?v=bbb"))
        #expect(YTDLPService.normalizedProbeKey("https://example.com/x?si=1") == "https://example.com/x?si=1")
    }

    @Test func firstOutputWatchdogIsFast() {
        // A hung SABR-gated extraction must fail into fallback in seconds,
        // not sit on "Preparing…" for minutes.
        #expect(YTDLPService.downloadFirstOutputTimeout <= 45)
    }

    @Test func thumbnailUnsupportedClassification() {
        // Real yt-dlp EmbedThumbnailPP failure shape (e.g. WAV target).
        let e = YTDLPService.classifyProbeError(
            stderr: "ERROR: Postprocessing: Supported filetypes for thumbnail embedding are: mp3, mkv/mka, ogg/opus/flac, m4a/mp4/m4v/mov")
        if case .thumbnailUnsupported = e {} else { Issue.record("expected thumbnailUnsupported") }
    }

    @Test func thumbnailUnsupportedNeverRetries() {
        // Deterministic container limitation: no other client can fix it, so
        // it must fail fast instead of burning every chain + auto-requeue.
        let e = YTDLPService.ServiceError.thumbnailUnsupported("x")
        #expect(!YTDLPService.shouldRetryDownloadChain(error: e, attemptsLeft: 3))
        #expect(!YTDLPService.shouldAutoRequeue(error: e, attemptsUsed: 0))
        #expect(!YTDLPService.isRetryableProbeError(e))
        #expect(YTDLPService.shortReason(for: e) == "can't carry cover art")
        #expect(!YTDLPService.shortReason(for: e).contains("android"))
    }

    @Test func safeTerminateNeverLaunchedDoesNotThrow() {
        // Regression: terminate() on a never-launched Process raises an
        // uncatchable NSInvalidArgumentException that took the whole app
        // down via cancel-all. Survival of this call IS the assertion.
        YTDLPService.safeTerminate(Process())
        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: "/bin/true")
        launched.standardOutput = Pipe()
        launched.standardError = Pipe()
        try? launched.run()
        launched.waitUntilExit()
        // Exited-but-launched: documented no-op, must also survive.
        YTDLPService.safeTerminate(launched)
    }

    @Test func cancelUnknownJobIsNoop() async {
        // No entry registered: must quietly do nothing, never crash.
        await YTDLPService().cancel(id: UUID())
    }
}
