import SwiftUI
import AppKit

enum SidebarDestination: String, Hashable, CaseIterable {
    case newBatch
    case queue
    case history
    case settings

    var title: String {
        switch self {
        case .newBatch: return "New Batch"
        case .queue: return "Queue"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .newBatch: return "plus.circle"
        case .queue: return "arrow.down.circle"
        case .history: return "clock"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(DownloadStore.self) private var store
    @State private var selection: SidebarDestination = .newBatch

    var body: some View {
        @Bindable var store = store
        Group {
            if store.backendReady {
                NavigationSplitView {
                    SidebarView(selection: $selection)
                } detail: {
                    switch selection {
                    case .newBatch:
                        NewBatchView()
                    case .queue:
                        QueueView()
                    case .history:
                        HistoryView()
                    case .settings:
                        SettingsView()
                    }
                }
            } else {
                LaunchGateView()
            }
        }
        .task {
            await store.runLaunchGate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .beatStashShowQueue)) { _ in
            selection = .queue
        }
        .sheet(isPresented: $store.showingTerms) {
            TermsView()
                .interactiveDismissDisabled()
        }
    }
}

/// Blocking readiness screen: the app proceeds only once yt-dlp is present
/// and current (or the user explicitly continues offline after a failure).
struct LaunchGateView: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Preparing BeatStash")
                .font(.title2)
            Text(store.backendStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
            if store.backendError == nil {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 240)
            } else {
                Text(store.backendError ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 12) {
                    Button("Retry") {
                        Task { await store.retryLaunchGate() }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Continue offline") {
                        store.continueOffline()
                    }
                }
            }
            Text("BeatStash ships yt-dlp and keeps it current automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// First-launch terms: running BeatStash means accepting yt-dlp auto-updates.
struct TermsView: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One thing before you start")
                .font(.title2)
            Text("BeatStash downloads music via yt-dlp, which breaks whenever YouTube changes its site — so BeatStash ships the latest yt-dlp and updates it automatically on every launch.")
            Text("By launching BeatStash, you agree to these automatic yt-dlp updates. Each check is tiny; a download (~35 MB from GitHub) happens only when a newer release exists, and installs into Application Support without touching the app itself.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Quit BeatStash") {
                    NSApplication.shared.terminate(nil)
                }
                Button("Agree & Continue") {
                    store.agreeTerms()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(DownloadStore())
    }
}
