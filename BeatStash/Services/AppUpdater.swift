import Foundation

/// BeatStash app self-update check (check-and-notify, GitHub releases).
/// Sits on top of yt-dlp's own updater: yt-dlp self-installs in place,
/// but the drag-installed app can't — so this only ever notifies, with a
/// one-click download link. Silent degrade by contract: before the first
/// GitHub release exists (or offline), every failure returns `.failed`,
/// which callers deliberately ignore.
///
/// Conventions mirror `BinaryManager`: 24h automatic-check interval,
/// `ignoreCache` for the manual Settings button, non-throwing outcome.
public enum AppUpdater: Sendable {
    nonisolated static let owner = "StitchProductions"
    nonisolated static let repo = "BeatStash"

    /// Download page for the latest release (what "Download update" opens).
    nonisolated static var releasesURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    /// Non-throwing outcome for the background check and Settings button.
    public enum Outcome: Sendable, Equatable {
        case upToDate(version: String)
        case available(version: String, url: URL)
        case skipped(reason: String)
        case failed(message: String)
    }

    nonisolated static let lastCheckKey = "appUpdateLastCheck"
    /// Minimum interval between automatic (non-manual) checks — the
    /// unauthenticated GitHub API allows 60/hr per IP.
    nonisolated static let checkInterval: TimeInterval = 24 * 3600

    /// Marketing version of the running app ("1.0.0"), nil in tests/previews
    /// where the host bundle carries no such key.
    public nonisolated static func currentVersion() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public nonisolated static func lastCheckDate() -> Date? {
        let t = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private struct GitHubRelease: Decodable {
        var tagName: String
        var htmlURL: URL?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Pure decision core (tested): tag from `releases/latest` vs running version.
    /// Tags carry a `v` prefix (`v1.0.0`) — `compareVersions` already strips it.
    nonisolated static func decide(current: String?, tag: String, htmlURL: URL?) -> Outcome {
        guard let current, !current.isEmpty else {
            return .skipped(reason: "Unknown current version.")
        }
        if BinaryManager.compareVersions(current, tag) == .orderedAscending {
            let version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            return .available(version: version, url: htmlURL ?? releasesURL)
        }
        return .upToDate(version: current)
    }

    /// Fetches `releases/latest` and decides. Never throws — failures come
    /// back as `.failed` (callers stay silent: no release yet, offline, or
    /// rate-limited all look the same on purpose).
    /// - Parameter ignoreCache: bypass the 24h interval (manual Check press).
    public static func checkForAppUpdate(ignoreCache: Bool = false) async -> Outcome {
        if !ignoreCache, let last = lastCheckDate(),
           Date().timeIntervalSince(last) < Self.checkInterval {
            return .skipped(reason: "Checked recently.")
        }
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!,
            timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failed(message: error.localizedDescription)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return .failed(message: "GitHub API returned status \(code).")
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            return .failed(message: "Couldn't parse release info.")
        }
        return decide(current: currentVersion(), tag: release.tagName, htmlURL: release.htmlURL)
    }
}
