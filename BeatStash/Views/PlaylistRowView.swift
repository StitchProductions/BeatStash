import SwiftUI

/// One playlist/batch row: checkbox + thumbnail + editable tags + per-track format.
struct PlaylistRowView: View {
    @Binding var job: DownloadJob
    var onEditTags: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $job.selected)
                .toggleStyle(.checkbox)
                .labelsHidden()

            AsyncImage(url: job.thumbnailURL.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quinary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
            }
            .frame(width: 72, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $job.tags.title, onEditingChanged: { _ in job.tagsEdited = true })
                    .font(.body)
                    .textFieldStyle(.plain)
                TextField("Artist", text: $job.tags.artist, onEditingChanged: { _ in job.tagsEdited = true })
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textFieldStyle(.plain)
                HStack(spacing: 6) {
                    Text(job.durationString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if job.tagsEdited {
                        Text("edited")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    if job.isFormatOverridden {
                        Text(job.audioFormat.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            Menu {
                ForEach(AudioFormat.allCases) { f in
                    Button {
                        job.audioFormat = f
                        // Overridden relative to batch default stored in UserDefaults.
                        let batchRaw = UserDefaults.standard.string(forKey: "defaultAudioFormat") ?? AudioFormat.m4a.rawValue
                        job.isFormatOverridden = (f.rawValue != batchRaw)
                    } label: {
                        Label(f.displayName, systemImage: job.audioFormat == f ? "checkmark" : "")
                    }
                }
            } label: {
                Text(job.audioFormat.rawValue.uppercased())
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quinary, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .help("Format for this track only")

            Button(action: onEditTags) {
                Image(systemName: "tag")
            }
            .buttonStyle(.borderless)
            .help("Edit tags (artist, album, track #)")
        }
        .padding(.vertical, 2)
        .opacity(job.selected ? 1 : 0.55)
    }
}
