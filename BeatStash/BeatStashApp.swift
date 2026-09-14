import SwiftUI

@main
struct BeatStashApp: App {
    @State private var store = DownloadStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
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
}
