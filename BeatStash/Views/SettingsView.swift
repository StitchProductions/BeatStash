import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(DownloadStore.self) private var store
    @AppStorage("defaultAudioFormat") private var defaultFormatRaw: String = AudioFormat.m4a.rawValue
    @AppStorage("maxConcurrent") private var maxConcurrent: Int = 3
    @AppStorage("destinationRoot") private var destinationRoot: String = ""
    @AppStorage("customYtDlpPath") private var customYtDlpPath: String = ""
    @AppStorage("customFfmpegPath") private var customFfmpegPath: String = ""
    @AppStorage("ytAuth.cookieMode") private var cookieModeRaw: String = YouTubeAuth.CookieMode.off.rawValue
    @AppStorage("ytAuth.browser") private var authBrowser: String = "firefox"
    @AppStorage("ytAuth.cookieFile") private var cookieFilePath: String = ""
    @AppStorage("ytAuth.poToken") private var poToken: String = ""
    @AppStorage("ytAuth.forceIPv4") private var forceIPv4: Bool = true
    @AppStorage("ytDlpChannel") private var channelRaw: String = BinaryManager.Channel.stable.rawValue

    @State private var updateOutput: String?
    @State private var isUpdating = false
    @State private var isChecking = false
    @State private var isInstalling = false
    @State private var toolsLoaded = false
    @State private var ffmpegFound: Bool?
    @State private var jsRuntime: String?
    @State private var ytAgeDays: Int?
    @State private var ytSource: String?
    @State private var ytPath: String?
    @State private var latestVersion: String?
    @State private var lastChecked: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Downloads") {
                HStack {
                    Text("Destination")
                    Spacer()
                    Text(store.destination.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseDestination() }
                }
                Picker("Default audio format", selection: Binding(
                    get: { AudioFormat(rawValue: defaultFormatRaw) ?? .m4a },
                    set: {
                        defaultFormatRaw = $0.rawValue
                        store.batchFormat = $0
                    }
                )) {
                    ForEach(AudioFormat.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                Stepper("Parallel downloads: \(maxConcurrent)", value: $maxConcurrent, in: 1...5)
                    .onChange(of: maxConcurrent) { _, new in store.maxConcurrent = new }
            }

            Section("Spotify") {
                Text("Songs resolve from Spotify in seconds and land in New Batch as YouTube searches that grab the first result. Review drafts by eye before downloading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tools (yt-dlp + ffmpeg)") {
                HStack {
                    Text("yt-dlp")
                    Spacer()
                    Text(ytDlpStatus)
                        .foregroundStyle(.secondary)
                        .font(.callout.monospaced())
                }
                if let latest = latestVersion {
                    HStack {
                        Text("Latest \(channelName)")
                        Spacer()
                        Text("v\(latest)")
                            .foregroundStyle(updateAvailable ? .orange : .secondary)
                            .font(.callout.monospaced())
                    }
                }
                if !toolsLoaded {
                    Text("Checking…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else if let path = ytPath {
                    HStack {
                        Text("Location")
                        Spacer()
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                } else {
                    Text("Searched the app bundle, Application Support, and system PATH — no yt-dlp found.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text("ffmpeg")
                    Spacer()
                    Text(ffmpegStatus)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Picker("Release channel", selection: $channelRaw) {
                    ForEach(BinaryManager.Channel.allCases, id: \.rawValue) { c in
                        Text(c.displayName).tag(c.rawValue)
                    }
                }
                .onChange(of: channelRaw) { _, _ in switchChannel() }
                Text("yt-dlp updates automatically on every launch (required to run BeatStash).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(isInstalling ? "Downloading…" : "Download yt-dlp") {
                        isInstalling = true
                        Task {
                            do {
                                _ = try await BinaryManager.shared.ensureYtDlp()
                                await store.bootstrap()
                                await refreshToolState()
                            } catch {
                                updateOutput = error.localizedDescription
                            }
                            isInstalling = false
                        }
                    }
                    .disabled(isInstalling || isUpdating || isChecking)

                    Button(isChecking ? "Checking…" : "Check for updates") {
                        isChecking = true
                        Task {
                            do {
                                let check = try await BinaryManager.shared.checkForUpdate()
                                latestVersion = check.latest
                                updateLastChecked()
                                updateOutput = check.available
                                    ? "Update available: v\(check.current ?? "?") → v\(check.latest)."
                                    : "yt-dlp is up to date (v\(check.current ?? check.latest))."
                                await refreshToolState()
                            } catch {
                                updateOutput = error.localizedDescription
                            }
                            isChecking = false
                        }
                    }
                    .disabled(isInstalling || isUpdating || isChecking)

                    Button(isUpdating ? "Updating…" : "Update yt-dlp") {
                        isUpdating = true
                        Task {
                            let outcome = await BinaryManager.shared.checkAndUpdateIfNeeded(ignoreCache: true)
                            updateOutput = outcomeMessage(outcome)
                            await store.bootstrap()
                            await refreshToolState()
                            isUpdating = false
                        }
                    }
                    .disabled(isInstalling || isUpdating || isChecking)
                }
                if let out = updateOutput {
                    Text(out)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let checked = lastChecked {
                    Text("Last checked \(checked).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("yt-dlp and ffmpeg ship with BeatStash — no Homebrew or separate install needed. Updates download automatically on launch (when enabled) and install to Application Support, leaving the app bundle untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("YouTube sign-in & bot-check") {
                Picker("Cookies", selection: $cookieModeRaw) {
                    ForEach(YouTubeAuth.CookieMode.allCases) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
                .onChange(of: cookieModeRaw) { _, _ in persistAuth() }

                if cookieModeRaw == YouTubeAuth.CookieMode.browser.rawValue {
                    Picker("Browser", selection: $authBrowser) {
                        ForEach(["firefox", "chrome", "brave", "edge", "safari"], id: \.self) { b in
                            Text(b.capitalized).tag(b)
                        }
                    }
                    .onChange(of: authBrowser) { _, _ in persistAuth() }
                    Text("Tip: quit the browser first for Chrome/Edge (locked cookie DB). Firefox is most reliable. Use a throwaway Google account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if cookieModeRaw == YouTubeAuth.CookieMode.file.rawValue {
                    HStack {
                        Text(cookieFilePath.isEmpty ? "No file imported" : cookieFilePath)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Import…") { importCookies() }
                        if !cookieFilePath.isEmpty {
                            Button("Clear") {
                                YouTubeAuth.clearCookiesFile()
                                cookieFilePath = ""
                                persistAuth()
                            }
                        }
                    }
                    Text("Export with “Get cookies.txt LOCALLY” after playing a video logged in. Stored with owner-only permissions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("PO token (advanced)")
                    Spacer()
                    SecureField("web.gvs+… (per-video, expires)", text: $poToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .font(.callout.monospaced())
                }
                .onChange(of: poToken) { _, _ in persistAuth() }

                Toggle("Force IPv4 (recommended — faster on most networks)", isOn: $forceIPv4)
                    .onChange(of: forceIPv4) { _, _ in persistAuth() }

                HStack {
                    Text("JS runtime")
                    Spacer()
                    Text(jsRuntime.map { "\($0) found" } ?? "none — `brew install deno` for hardest videos")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Text("Anonymous videos work without sign-in. Age-restricted / members-only / bot-checked videos need cookies; the rare SABR-gated ones also need a JS runtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced (custom binaries)") {
                HStack {
                    Text("yt-dlp path")
                    Spacer()
                    TextField("/opt/homebrew/bin/yt-dlp", text: $customYtDlpPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .font(.callout.monospaced())
                }
                HStack {
                    Text("ffmpeg path")
                    Spacer()
                    TextField("/opt/homebrew/bin/ffmpeg", text: $customFfmpegPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .font(.callout.monospaced())
                }
                Button("Re-detect binaries") {
                    Task {
                        await BinaryManager.shared.locate(force: true)
                        await store.bootstrap()
                        await refreshToolState()
                    }
                }
            }

            Section("About formats") {
                Text("YouTube audio is lossy at the source (Opus/AAC). WAV/FLAC re-wrap it for DAW compatibility — larger files, same fidelity. WAV tags are minimal by spec.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .padding()
        .onAppear {
            if destinationRoot.isEmpty {
                destinationRoot = AppSettings.defaultDestination.path
            }
        }
        .task {
            await BinaryManager.shared.locate()
            await refreshToolState()
        }
    }

    // MARK: - Tools state

    private var channelName: String {
        (BinaryManager.Channel(rawValue: channelRaw) ?? .stable).displayName.lowercased()
    }

    private var updateAvailable: Bool {
        guard let latest = latestVersion, let current = store.ytDlpVersion else { return false }
        return BinaryManager.compareVersions(current, latest) == .orderedAscending
    }

    private var ytDlpStatus: String {
        guard let v = store.ytDlpVersion else { return "not found" }
        var s = "v\(v)"
        if let age = ytAgeDays { s += " · \(age) days old" }
        if let src = ytSource { s += " · \(src.lowercased())" }
        return s
    }

    private func refreshToolState() async {
        ffmpegFound = await BinaryManager.shared.ffmpegPath != nil
        jsRuntime = await BinaryManager.shared.jsRuntimeName()
        ytAgeDays = await BinaryManager.shared.ytDlpAgeDays()
        ytSource = await BinaryManager.shared.activeSource().displayName
        ytPath = await BinaryManager.shared.ytDlpPath
        if let cached = await BinaryManager.shared.cachedLatestVersion() {
            latestVersion = cached
        }
        updateLastChecked()
        toolsLoaded = true
    }

    private func updateLastChecked() {
        Task {
            if let date = await BinaryManager.shared.lastCheckDate() {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .short
                lastChecked = f.localizedString(for: date, relativeTo: Date())
            } else {
                lastChecked = nil
            }
        }
    }

    private func outcomeMessage(_ outcome: BinaryManager.UpdateOutcome) -> String {
        switch outcome {
        case .upToDate(let v): return "yt-dlp is up to date (v\(v))."
        case .updated(let from, let to):
            return "Updated yt-dlp\(from.map { " from v\($0)" } ?? "") to v\(to)."
        case .skipped(let r): return r
        case .failed(let m): return m
        }
    }

    private func switchChannel() {
        let channel = BinaryManager.Channel(rawValue: channelRaw) ?? .stable
        isUpdating = true
        updateOutput = "Switching to \(channel.displayName.lowercased())…"
        Task {
            let outcome = await BinaryManager.shared.reinstallFromChannel(channel)
            updateOutput = outcomeMessage(outcome)
            await store.bootstrap()
            await refreshToolState()
            isUpdating = false
        }
    }

    private func persistAuth() {
        YouTubeAuth(
            cookieMode: YouTubeAuth.CookieMode(rawValue: cookieModeRaw) ?? .off,
            browser: authBrowser,
            cookieFilePath: cookieFilePath.isEmpty ? nil : cookieFilePath,
            manualPoToken: poToken,
            forceIPv4: forceIPv4
        ).save()
    }

    private func importCookies() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a cookies.txt file (Netscape format)."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                cookieFilePath = try YouTubeAuth.importCookiesFile(from: url)
                persistAuth()
                updateOutput = "Imported cookies to \(cookieFilePath)"
            } catch {
                updateOutput = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private var ffmpegStatus: String {
        switch ffmpegFound {
        case .some(true): return "bundled"
        case .some(false): return "not found — reinstall BeatStash or set a custom path below"
        case .none: return "checking…"
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            destinationRoot = url.path
            store.destination = url
        }
    }
}
