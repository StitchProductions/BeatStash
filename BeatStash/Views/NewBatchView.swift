import SwiftUI
import AppKit

struct NewBatchView: View {
    @Environment(DownloadStore.self) private var store
    @State private var showTagEditor: UUID?
    @State private var showApplyAllConfirm = false
    @State private var pendingBatchFormat: AudioFormat = .m4a

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            // Setup banner
            if let msg = store.setupMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(msg)
                        .font(.callout)
                    Spacer()
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .padding()
            }

            // URL input card
            VStack(alignment: .leading, spacing: 8) {
                Text("YouTube link or playlist")
                    .font(.headline)
                Text("Paste a video, playlist, or multiple links (one per line). Public and unlisted only in v1.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    TextEditor(text: $store.urlText)
                        .font(.body.monospaced())
                        .frame(minHeight: 56, maxHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                    VStack {
                        if store.isFetching {
                            Button(role: .destructive) {
                                store.cancelFetch()
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .keyboardShortcut(".", modifiers: .command)
                        } else {
                            Button {
                                Task { await store.fetch() }
                            } label: {
                                Label("Fetch info", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("Preview tracks, tags, and formats — downloads nothing")

                            Button {
                                Task { await store.fetchAndDownloadAll() }
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("Fetch everything and start downloading in the chosen format")
                        }

                        Button {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                store.urlText = s
                                Task { await store.fetch() }
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                HStack {
                    Picker("Mode", selection: $store.batchMode) {
                        Text("Audio").tag(DownloadKind.audio)
                        Text("Video").tag(DownloadKind.video)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    if store.batchMode == .video {
                        Picker("Quality", selection: $store.videoQuality) {
                            ForEach(VideoQuality.allCases) { q in
                                Text(q.displayName).tag(q)
                            }
                        }
                        .frame(width: 160)
                    } else {
                        Menu {
                            ForEach(AudioFormat.allCases) { f in
                                Button(f.displayName) {
                                    if store.overriddenFormatCount > 0 && f != store.batchFormat {
                                        pendingBatchFormat = f
                                        showApplyAllConfirm = true
                                    } else {
                                        store.applyBatchFormat(f)
                                    }
                                }
                            }
                        } label: {
                            Label("Format for all: \(store.batchFormat.displayName)", systemImage: "music.note")
                        }
                        .menuStyle(.borderlessButton)
                    }

                    Spacer()

                    if store.isFetching {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text("\(store.fetchProgress ?? "Fetching info…") (Cancel with ⌘.)").foregroundStyle(.secondary)
                        Button("Cancel") { store.cancelFetch() }
                            .buttonStyle(.link)
                    } else if let err = store.fetchError {
                        Label(err, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .lineLimit(3)
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(err, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.link)
                        .help("Copy error")
                    } else if let title = store.probeTitle {
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

            // Draft list
            if !store.draftJobs.isEmpty {
                HStack {
                    Button(store.allSelected ? "Deselect all" : "Select all") {
                        store.setAllSelected(!store.allSelected)
                    }
                    .buttonStyle(.link)
                    Button("Clear list") {
                        store.clearDrafts()
                    }
                    .buttonStyle(.link)
                    .help("Remove all fetched tracks — your pasted links stay")
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text("\(store.selectedDrafts.count) of \(store.draftJobs.count) selected")
                        .foregroundStyle(.secondary)
                    if store.editedTagCount > 0 {
                        Text("• \(store.editedTagCount) tags edited")
                            .foregroundStyle(.secondary)
                    }
                    if store.overriddenFormatCount > 0 {
                        Text("• \(store.overriddenFormatCount) custom formats")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.needsEnrichment {
                        Button("Get full details") {
                            Task { await store.enrichDrafts() }
                        }
                        .buttonStyle(.link)
                        .help("Fetch durations and years for these tracks (slower full probe)")
                    }
                    Text("Est. \(String(format: "%.0f", store.estimatedSizeMB)) MB")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .help("Estimate from duration × format bitrate. WAV/FLAC are large.")
                }
                .font(.callout)
                .padding(.horizontal)
                .padding(.top, 8)

                List {
                    ForEach($store.draftJobs) { $job in
                        PlaylistRowView(job: $job, onEditTags: { showTagEditor = job.id })
                    }
                }
                .listStyle(.inset)

                if let f = store.batchFormat.footnote, store.batchMode == .audio {
                    Text(f)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                // Bottom bar
                HStack {
                    Text("Destination")
                        .foregroundStyle(.secondary)
                    Text(store.destination.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseDestination() }
                        .buttonStyle(.link)
                    Button {
                        store.enqueueSelected()
                    } label: {
                        Label("Download \(store.selectedDrafts.count)", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.selectedDrafts.isEmpty)
                }
                .padding()
                .background(.bar)
            } else if !store.isFetching {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("Paste a link to preview tracks")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Fetch info previews without downloading — Download grabs everything in your format.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .navigationTitle("New Batch")
        .onReceive(NotificationCenter.default.publisher(for: .beatStashPasteFetch)) { _ in
            if let s = NSPasteboard.general.string(forType: .string) {
                store.urlText = s
                Task { await store.fetch() }
            }
        }
        .sheet(isPresented: Binding(
            get: { showTagEditor != nil },
            set: { if !$0 { showTagEditor = nil } }
        )) {
            if let id = showTagEditor,
               let idx = store.draftJobs.firstIndex(where: { $0.id == id }) {
                TagEditorView(
                    job: $store.draftJobs[idx],
                    playlistTitle: store.probeTitle,
                    onApplyAlbumToAll: { store.applyAlbumToAll($0) }
                )
            }
        }
        .confirmationDialog(
            "Change format for all tracks?",
            isPresented: $showApplyAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Apply to all (reset overrides)") {
                store.applyBatchFormat(pendingBatchFormat, force: true)
            }
            Button("Keep per-track overrides") {
                store.applyBatchFormat(pendingBatchFormat, force: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(store.overriddenFormatCount) tracks have a custom format.")
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            store.destination = url
            UserDefaults.standard.set(url.path, forKey: "destinationRoot")
        }
    }
}
