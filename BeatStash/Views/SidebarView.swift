import SwiftUI

struct SidebarView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var selection: SidebarDestination

    var body: some View {
        List(selection: $selection) {
            Section("Downloads") {
                NavigationLink(value: SidebarDestination.newBatch) {
                    Label("New Batch", systemImage: "plus.circle")
                }
                NavigationLink(value: SidebarDestination.queue) {
                    Label {
                        HStack {
                            Text("Queue")
                            if store.activeCount > 0 {
                                Text("\(store.activeCount)")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.tint, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                NavigationLink(value: SidebarDestination.history) {
                    Label("History", systemImage: "clock")
                }
            }
            Section("App") {
                NavigationLink(value: SidebarDestination.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("BeatStash")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let v = store.ytDlpVersion {
                    Text("yt-dlp \(v)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("yt-dlp …")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !store.binariesReady {
                    Text("Setup needed")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
