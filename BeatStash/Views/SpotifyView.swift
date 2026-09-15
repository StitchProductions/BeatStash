import SwiftUI
import AppKit

struct SpotifyView: View {
    @Environment(SpotifyImportStore.self) private var imports
    @Environment(DownloadStore.self) private var store

    var body: some View {
        @Bindable var imports = imports
        VStack(spacing: 0) {
            // Link card
            VStack(alignment: .leading, spacing: 8) {
                Text("Spotify playlist or track")
                    .font(.headline)
                Text("Paste a public playlist link — each song resolves in seconds, then lands in New Batch as a YouTube search that grabs the first result. No login or API key needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    TextField("https://open.spotify.com/playlist/…", text: $imports.urlText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .disabled(imports.isImporting)

                    VStack {
                        if imports.isImporting {
                            Button(role: .destructive) {
                                imports.cancelImport()
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                Task { await imports.importFromURL() }
                            } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(imports.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        Button {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                imports.urlText = s
                                Task { await imports.importFromURL() }
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        .disabled(imports.isImporting)
                    }
                }

                HStack {
                    if imports.isImporting {
                        ProgressView().scaleEffect(0.8)
                        Text(imports.progress ?? "Working…").foregroundStyle(.secondary)
                        Button("Cancel") { imports.cancelImport() }
                            .buttonStyle(.link)
                    } else if let err = imports.errorMessage {
                        Label(err, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    } else if let title = imports.playlistTitle {
                        Label(title, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .lineLimit(1)
                    }
                }
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .padding([.horizontal, .top])

            // Track list
            if !imports.tracks.isEmpty {
                HStack {
                    Button(imports.allSelectableSelected ? "Deselect all" : "Select all") {
                        imports.setAllSelectable(!imports.allSelectableSelected)
                    }
                    .buttonStyle(.link)
                    .disabled(imports.resolvedCount == 0)
                    Button("Clear all") {
                        imports.clearTracks()
                    }
                    .buttonStyle(.link)
                    .help("Remove all imported tracks — your pasted link stays")
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text("\(imports.selectedResolvedCount) of \(imports.tracks.count) selected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(imports.resolvedCount) resolved")
                        .foregroundStyle(.secondary)
                    if imports.failedCount > 0, !imports.isImporting {
                        Button("Retry failed (\(imports.failedCount))") {
                            Task { await imports.retryFailed() }
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.callout)
                .padding(.horizontal)
                .padding(.top, 8)

                List {
                    ForEach($imports.tracks) { $track in
                        SpotifyTrackRow(track: $track)
                    }
                }
                .listStyle(.inset)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("First YouTube result wins per song — untick anything that looks wrong before adding.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if imports.isImporting {
                            Text("Resolving… Add is available when done.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        _ = imports.addSelectedToBatch(store)
                    } label: {
                        Label("Add \(imports.selectedResolvedCount) to New Batch", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!imports.canAddToBatch)
                    .help(imports.isImporting ? "Wait until resolving finishes" : "Add selected songs to New Batch")
                }
                .padding()
                .background(.bar)
            } else if !imports.isImporting {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("Import a Spotify playlist")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Songs resolve in seconds — then add them to your downloads.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .navigationTitle("Spotify")
    }
}

struct SpotifyTrackRow: View {
    @Environment(SpotifyImportStore.self) private var imports
    @Binding var track: SpotifyImportTrack

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $track.selected)
                .toggleStyle(.checkbox)
                .disabled(!isResolved)
            if let art = track.artworkURL, let url = URL(string: art) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4).fill(.quinary)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quinary)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statusLine
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var isResolved: Bool {
        if case .resolved = track.status { return true }
        return false
    }

    @ViewBuilder
    private var statusLine: some View {
        switch track.status {
        case .working:
            Text("Resolving…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .resolved:
            if let album = track.deezerAlbum, !album.isEmpty {
                Text(album)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                if !imports.isImporting {
                    Button("Retry") {
                        Task { await imports.retryTrack(id: track.id) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }
}
