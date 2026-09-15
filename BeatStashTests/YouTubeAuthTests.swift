import Foundation
import Testing
@testable import BeatStash

struct YouTubeAuthTests {
    /// Fresh suite plus its name so the test can remove the domain after —
    /// otherwise every run leaks a plist into ~/Library/Preferences.
    private func freshDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "BeatStashTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaultsAreAnonymousWithIPv4On() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let auth = YouTubeAuth.load(defaults: defaults)
        #expect(auth.cookieMode == .off)
        #expect(!auth.hasCookies)
        #expect(auth.forceIPv4) // measured ~30% faster probes; toggle opts out
    }

    @Test func anonymousArgs() {
        var auth = YouTubeAuth()
        auth.forceIPv4 = false
        auth.manualPoToken = ""
        #expect(auth.authArgs().isEmpty)
    }

    @Test func ipv4FlagEmitted() {
        #expect(YouTubeAuth().authArgs().contains("--force-ipv4"))
    }

    @Test func browserCookies() {
        var auth = YouTubeAuth()
        auth.cookieMode = .browser
        auth.browser = "firefox"
        auth.forceIPv4 = false
        #expect(auth.authArgs() == ["--cookies-from-browser", "firefox"])
        #expect(auth.hasCookies)
    }

    @Test func anonymousChains() {
        let chains = YouTubeAuth().clientChains()
        // Default first: full formats on a clean IP; mobile stays as fallback
        // for sign-in bot-walls (verified 2026-09-15, Hjw86NcG8Bo).
        #expect(chains.first == ["default"])
        #expect(chains.count == 4)
        #expect(chains.contains(["android", "ios", "tv"]))
    }

    @Test func tvNeverPairedWithCookies() {
        var auth = YouTubeAuth()
        auth.cookieMode = .browser
        auth.browser = "firefox"
        for chain in auth.clientChains() {
            #expect(!chain.contains("tv"))
        }
        #expect(auth.clientChains().first == ["default", "web_embedded"])
    }

    @Test func clientArgsFormat() {
        #expect(YouTubeAuth.clientArgs(for: ["android", "ios"]) ==
            ["--extractor-args", "youtube:player_client=android,ios"])
    }

    @Test func networkHardeningPresent() {
        #expect(YouTubeAuth.networkArgs.contains("--socket-timeout"))
        #expect(YouTubeAuth.networkArgs.contains("--retries"))
    }

    @Test func roundTripPersistence() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var auth = YouTubeAuth()
        auth.cookieMode = .browser
        auth.browser = "chrome"
        auth.forceIPv4 = false
        auth.save(defaults: defaults)
        let loaded = YouTubeAuth.load(defaults: defaults)
        #expect(loaded.cookieMode == .browser)
        #expect(loaded.browser == "chrome")
        #expect(!loaded.forceIPv4)
    }
}
