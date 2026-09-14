import SwiftUI

@main
struct BeatStashApp: App {
    @State private var store = DownloadStore()
    @State private var spotifyStore = SpotifyImportStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(spotifyStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Download") {
                Button("Paste and Fetch") {
                    NotificationCenter.default.post(name: .beatStashPasteFetch, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

extension Notification.Name {
    static let beatStashPasteFetch = Notification.Name("beatStashPasteFetch")
    static let beatStashShowQueue = Notification.Name("beatStashShowQueue")
    static let beatStashShowNewBatch = Notification.Name("beatStashShowNewBatch")
}
