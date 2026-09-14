import Foundation
import Testing
@testable import BeatStash

/// Download recovery: chain fallback for transient rejections, bounded
/// auto-requeue for self-healing failures, fast failure for terminal ones.
@MainActor
struct DownloadRetryTests {
    @Test func chainRetryableErrors() {
        for e: YTDLPService.ServiceError in [
            .reloadRequired("x"), .networkError("x"), .formatGated("x"),
            .botCheck("x"), .probeTimeout(1), .clientFailed("x"),
            .downloadFailed("unknown"),
        ] {
            #expect(YTDLPService.shouldRetryDownloadChain(error: e, attemptsLeft: 1))
        }
    }

    @Test func chainTerminalErrors() {
        for e: YTDLPService.ServiceError in [
            .loginRequired("x"), .videoUnavailable("x"), .parseFailed("x"),
            .missingBinary, .outputNotFound,
        ] {
            #expect(!YTDLPService.shouldRetryDownloadChain(error: e, attemptsLeft: 2))
        }
    }

    @Test func chainBudgetExhausted() {
        #expect(!YTDLPService.shouldRetryDownloadChain(
            error: YTDLPService.ServiceError.reloadRequired("x"), attemptsLeft: 0))
    }

    @Test func autoRequeueOnlySelfHealing() {
        #expect(YTDLPService.shouldAutoRequeue(
            error: YTDLPService.ServiceError.reloadRequired("x"), attemptsUsed: 0))
        #expect(YTDLPService.shouldAutoRequeue(
            error: YTDLPService.ServiceError.networkError("x"), attemptsUsed: 1))
        // Capped at 2 silent retries (3 total attempts).
        #expect(!YTDLPService.shouldAutoRequeue(
            error: YTDLPService.ServiceError.reloadRequired("x"), attemptsUsed: 2))
        // Bot-checks need cookies, gated formats need other clients — the
        // chain loop already covers those; the store must not loop them.
        #expect(!YTDLPService.shouldAutoRequeue(
            error: YTDLPService.ServiceError.botCheck("x"), attemptsUsed: 0))
        #expect(!YTDLPService.shouldAutoRequeue(
            error: YTDLPService.ServiceError.formatGated("x"), attemptsUsed: 0))
        #expect(!YTDLPService.shouldAutoRequeue(
            error: YTDLPService.ServiceError.loginRequired("x"), attemptsUsed: 0))
        #expect(!YTDLPService.shouldAutoRequeue(
            error: NSError(domain: "x", code: 1), attemptsUsed: 0))
    }

    @Test func chainInjectedIntoArgs() async {
        let args = await YTDLPService().buildArguments(
            job: DownloadJob(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                             kind: .audio, displayTitle: "T"),
            directory: URL(fileURLWithPath: "/tmp"),
            auth: YouTubeAuth(), chain: ["web_embedded"])
        #expect(args.contains("youtube:player_client=web_embedded"))
    }

    @Test func defaultChainUnchanged() async {
        // No explicit chain: first chain as before (no behavior change).
        let args = await YTDLPService().buildArguments(
            job: DownloadJob(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                             kind: .audio, displayTitle: "T"),
            directory: URL(fileURLWithPath: "/tmp"))
        #expect(args.contains("youtube:player_client=android,ios,tv"))
    }
}
