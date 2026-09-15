import SwiftUI
import AppKit

struct QueueView: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.queue.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("Queue is empty")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Fetch a playlist in New Batch, then press Download.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                HStack {
                    Text("\(store.queue.count) jobs • \(store.activeCount) active • \(store.finishedCount) done")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                    Button("Cancel all") { store.cancelAll() }
                        .buttonStyle(.link)
                        .disabled(store.activeCount == 0)
                    Button("Clear finished") { store.clearFinished() }
                        .buttonStyle(.link)
                        .disabled(store.finishedCount == 0 && !store.queue.contains(where: { $0.status == .failed || $0.status == .cancelled }))
                }
                .padding()

                List {
                    ForEach($store.queue) { $job in
                        QueueRowView(job: $job)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Queue")
    }
}

struct QueueRowView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var job: DownloadJob

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(job.tags.isEmpty ? job.displayTitle : job.tags.displayLine)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(job.kind == .audio ? job.audioFormat.displayName : job.videoQuality.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if store.preparingIDs.contains(job.id), job.status == .downloading {
                        Text(job.phaseLabel ?? "Preparing…").font(.caption).foregroundStyle(.secondary)
                    }
                    if job.status == .tagging {
                        Text(job.phaseLabel ?? "Tagging…").font(.caption).foregroundStyle(.secondary)
                    }
                    if let s = job.speedString, job.status == .downloading {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                    if let e = job.etaString, job.status == .downloading {
                        Text("ETA \(e)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let err = job.errorMessage,
                       job.status == .failed || job.status == .queued {
                        Text(err).font(.caption).foregroundStyle(job.status == .failed ? .red : .secondary).lineLimit(2)
                    }
                }
                if job.status.isActive {
                    if store.preparingIDs.contains(job.id) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 320)
                    } else {
                        ProgressView(value: job.progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 320)
                    }
                } else if job.status == .completed {
                    Text("Saved: \(job.outputPath ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = job.tagNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if job.status.isActive {
                Button("Cancel") { store.cancel(id: job.id) }
                    .buttonStyle(.link)
            } else if job.status == .failed || job.status == .cancelled {
                Button("Retry") { store.retry(id: job.id) }
                    .buttonStyle(.link)
            }
            if job.status == .completed, job.outputPath != nil {
                Button("Show in Finder") { reveal(job) }
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .fetching, .tagging:
            // Native small spinner: a scaleEffect here trips the AppKit
            // bridge's min <= max check on every row re-render (console spam
            // during downloads) for the same visual size.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .downloading:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func reveal(_ job: DownloadJob) {
        guard let p = job.outputPath else { return }
        let fm = FileManager.default
        // outputPath may be a directory (when newest-file resolution failed) — handle both.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        } else if isDir.boolValue {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        } else {
            // File moved/deleted since download: reveal the parent when it
            // exists instead of handing Finder a dead URL.
            let parent = URL(fileURLWithPath: p).deletingLastPathComponent().path
            var parentIsDir: ObjCBool = false
            if fm.fileExists(atPath: parent, isDirectory: &parentIsDir), parentIsDir.boolValue {
                NSWorkspace.shared.open(URL(fileURLWithPath: parent))
            }
        }
    }
}
