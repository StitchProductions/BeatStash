import Foundation
import Testing
@testable import BeatStash

/// App self-update decisions: pure tag-vs-version matrix, no network.
/// The live fetch is intentionally untested (same discipline as the
/// yt-dlp updater — fixtures would just re-assert URLSession).
@MainActor
struct AppUpdaterTests {
    @Test func upToDateWhenEqualOrNewer() {
        #expect(AppUpdater.decide(current: "1.0.0", tag: "v1.0.0", htmlURL: nil)
            == .upToDate(version: "1.0.0"))
        #expect(AppUpdater.decide(current: "1.1.0", tag: "v1.0.0", htmlURL: nil)
            == .upToDate(version: "1.1.0"))
    }

    @Test func availableStripsVPrefix() {
        let url = URL(string: "https://github.com/StitchProductions/BeatStash/releases/tag/v1.1.0")!
        #expect(AppUpdater.decide(current: "1.0.0", tag: "v1.1.0", htmlURL: url)
            == .available(version: "1.1.0", url: url))
    }

    @Test func availableFallsBackToReleasesPage() {
        #expect(AppUpdater.decide(current: "1.0.0", tag: "v2.0.0", htmlURL: nil)
            == .available(version: "2.0.0", url: AppUpdater.releasesURL))
    }

    @Test func unknownCurrentVersionSkips() {
        // Running somewhere without a marketing version (previews, odd
        // hosts): never nag, never fail loudly.
        if case .skipped = AppUpdater.decide(current: nil, tag: "v9.9.9", htmlURL: nil) {
        } else {
            Issue.record("expected skipped with nil current version")
        }
        if case .skipped = AppUpdater.decide(current: "", tag: "v9.9.9", htmlURL: nil) {
        } else {
            Issue.record("expected skipped with empty current version")
        }
    }

    @Test func releasesURLEndsAtLatest() {
        #expect(AppUpdater.releasesURL.absoluteString ==
            "https://github.com/StitchProductions/BeatStash/releases/latest")
    }
}
