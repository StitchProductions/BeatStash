import SwiftUI
import AppKit

struct HistoryView: View {
    @Environment(DownloadStore.self) private var store
    @State private var query: String = ""

    var filtered: [HistoryEntry] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return store.history }
        let q = query.lowercased()
        return store.history.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack {
            if store.history.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("No downloads yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(filtered) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.artist.isEmpty ? entry.title : "\(entry.artist) – \(entry.title)")
                                .lineLimit(1)
                            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) • \(entry.format.uppercased())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show in Finder") {
                            if FileManager.default.fileExists(atPath: entry.filePath) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.filePath)])
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .searchable(text: $query, prompt: "Search artist or title")
    }
}
