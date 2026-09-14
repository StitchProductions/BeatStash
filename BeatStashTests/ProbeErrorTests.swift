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

    @Test func searchRetryPolicy() {
        for e: YTDLPService.ServiceError in
            [.botCheck("x"), .networkError("x"), .probeTimeout(1)] {
            #expect(YTDLPService.isSearchRetryable(e))
        }
        for e: YTDLPService.ServiceError in
            [.loginRequired("x"), .videoUnavailable("x"), .formatGated("x"),
             .parseFailed("x"), .missingBinary] {
            #expect(!YTDLPService.isSearchRetryable(e))
        }
        #expect(!YTDLPService.isSearchRetryable(NSError(domain: "x", code: 1)))
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
}
