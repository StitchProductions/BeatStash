import SwiftUI

/// Full tag editor sheet for one job.
struct TagEditorView: View {
    @Binding var job: DownloadJob
    var playlistTitle: String?
    var onApplyAlbumToAll: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit tags")
                .font(.headline)
            Text(job.displayTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Artist").foregroundStyle(.secondary)
                    TextField("Artist", text: $job.tags.artist)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: job.tags.artist) { _, _ in job.tagsEdited = true }
                }
                GridRow {
                    Text("Title").foregroundStyle(.secondary)
                    TextField("Title", text: $job.tags.title)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: job.tags.title) { _, _ in job.tagsEdited = true }
                }
                GridRow {
                    Text("Album").foregroundStyle(.secondary)
                    HStack {
                        TextField("Album", text: $job.tags.album)
                            .textFieldStyle(.roundedBorder)
                        Button("All") {
                            onApplyAlbumToAll(job.tags.album)
                        }
                        .help("Apply this album to all tracks in the batch")
                    }
                    .onChange(of: job.tags.album) { _, _ in job.tagsEdited = true }
                }
                GridRow {
                    Text("Track #").foregroundStyle(.secondary)
                    TextField("3", value: Binding(
                        get: { job.tags.trackNumber ?? 0 },
                        set: { job.tags.trackNumber = $0 == 0 ? nil : $0; job.tagsEdited = true }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                }
                GridRow {
                    Text("Year").foregroundStyle(.secondary)
                    TextField("2024", text: Binding(
                        get: { job.tags.year ?? "" },
                        set: { job.tags.year = $0; job.tagsEdited = true }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                }
                GridRow {
                    Text("Genre").foregroundStyle(.secondary)
                    TextField("Optional", text: Binding(
                        get: { job.tags.genre ?? "" },
                        set: { job.tags.genre = $0.isEmpty ? nil : $0; job.tagsEdited = true }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            Text("WAV note: WAV tagging is minimal by spec (INFO + BWF only) — Finder/Music may not show it. Tags still saved to History.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Reset to autofill") {
                    let parsed = TagParser.parse(
                        title: job.displayTitle,
                        uploader: job.tags.artist,
                        playlistTitle: playlistTitle,
                        playlistIndex: job.playlistIndex
                    )
                    job.tags = parsed
                    job.tagsEdited = false
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }
}
