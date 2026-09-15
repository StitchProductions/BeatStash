import Foundation
import Testing
@testable import BeatStash

/// Download planning: ffmpeg discovery for postprocessing, and reuse of
/// fresh probe dumps so downloads skip re-extraction.
@MainActor
struct DownloadArgsTests {
    @Test func ffmpegLocationMissing() {
        #expect(YTDLPService.ffmpegLocationArgs(ffmpegPath: nil).isEmpty)
        #expect(YTDLPService.ffmpegLocationArgs(ffmpegPath: "").isEmpty)
    }

    @Test func ffmpegLocationDirectory() {
        #expect(YTDLPService.ffmpegLocationArgs(
            ffmpegPath: "/Applications/BeatStash.app/Contents/Resources/bin/ffmpeg")
            == ["--ffmpeg-location", "/Applications/BeatStash.app/Contents/Resources/bin"])
        #expect(YTDLPService.ffmpegLocationArgs(ffmpegPath: "/opt/homebrew/bin/ffmpeg")
            == ["--ffmpeg-location", "/opt/homebrew/bin"])
    }

    @Test func usableFormatURLs() throws {
        let gated = try JSONDecoder().decode(MediaInfo.self, from: Data("""
            {"id":"x","formats":[{"format_id":"18"},{"format_id":"22"}]}
            """.utf8))
        #expect(YTDLPService.usableFormatURLs(in: gated).isEmpty)

        let good = try JSONDecoder().decode(MediaInfo.self, from: Data("""
            {"id":"x","formats":[{"format_id":"18"},
             {"format_id":"22","url":"https://example.com/v.mp4"}]}
            """.utf8))
        #expect(YTDLPService.usableFormatURLs(in: good) == ["https://example.com/v.mp4"])

        let bare = try JSONDecoder().decode(MediaInfo.self, from: Data("{}".utf8))
        #expect(YTDLPService.usableFormatURLs(in: bare).isEmpty)
    }

    @Test func sharedArgsNeverBakeLoadInfo() {
        // --load-info-json is a per-download freshness decision, never part of
        // the shared probe/download arg prefixes.
        #expect(!YTDLPService.probeBaseArgs(auth: YouTubeAuth(), chain: ["android"]).contains("--load-info-json"))
        #expect(!YouTubeAuth.networkArgs.contains("--load-info-json"))
    }

    private func tags() -> TrackTags {
        TrackTags(artist: "A", title: "T", album: "Alb", trackNumber: 3,
                  year: "2020", genre: "Pop")
    }

    @Test func tagArgsWithoutArt() {
        let mp3 = YTDLPService.tagOutputArgs(tags: tags(), format: .mp3, artPath: nil)
        #expect(mp3.contains("-id3v2_version"))
        #expect(mp3.contains("-c"))
        #expect(!mp3.contains("attached_pic"))
        #expect(!mp3.contains("-map"))

        let wav = YTDLPService.tagOutputArgs(tags: tags(), format: .wav, artPath: nil)
        #expect(wav.contains("-write_bext"))
    }

    @Test func tagArgsWithArt() {
        for format: AudioFormat in [.mp3, .m4a, .flac, .opus] {
            let args = YTDLPService.tagOutputArgs(
                tags: tags(), format: format, artPath: "/tmp/a.jpg")
            // Audio re-mapped (drops any YouTube thumbnail) + art attached.
            #expect(args.contains("-map"), "\(format)")
            #expect(args.contains("attached_pic"), "\(format)")
            #expect(args.contains("-metadata"), "\(format)")
        }
    }

    @Test func tagArgsWavIgnoresArt() {
        // WAV cover support is spec-poor: art must never alter the command.
        let plain = YTDLPService.tagOutputArgs(tags: tags(), format: .wav, artPath: nil)
        let withArt = YTDLPService.tagOutputArgs(tags: tags(), format: .wav, artPath: "/tmp/a.jpg")
        #expect(plain == withArt)
        #expect(!withArt.contains("attached_pic"))
    }

    @Test func thumbnailEmbedGatedPerFormat() {
        // yt-dlp hard-fails the whole job when asked to embed into WAV
        // (after download + transcode), so WAV must never get the flags.
        #expect(YTDLPService.thumbnailEmbedArgs(for: .wav).isEmpty)
        for format: AudioFormat in [.mp3, .m4a, .flac, .opus] {
            let args = YTDLPService.thumbnailEmbedArgs(for: format)
            #expect(args.contains("--embed-thumbnail"), "\(format)")
            #expect(args.contains("--convert-thumbnails"), "\(format)")
        }
    }

    @Test func wavDownloadSkipsEmbedFlags() async {
        let wavArgs = await YTDLPService().buildArguments(
            job: DownloadJob(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                             kind: .audio, displayTitle: "T", audioFormat: .wav),
            directory: URL(fileURLWithPath: "/tmp"),
            auth: YouTubeAuth(), chain: ["default"])
        #expect(!wavArgs.contains("--embed-thumbnail"))
        #expect(!wavArgs.contains("--convert-thumbnails"))
        // No thumbnail download of any kind for WAV — the music folder must
        // end up with just the audio file.
        #expect(!wavArgs.contains("--write-thumbnail"))
        #expect(!wavArgs.contains("--write-all-thumbnails"))
        #expect(!wavArgs.contains(where: { $0.hasPrefix("thumbnail:") }))
        // Conversion + text metadata still apply — only the cover step is cut.
        #expect(wavArgs.contains("--audio-format"))
        #expect(wavArgs.contains("--add-metadata"))

        let mp3Args = await YTDLPService().buildArguments(
            job: DownloadJob(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                             kind: .audio, displayTitle: "T", audioFormat: .mp3),
            directory: URL(fileURLWithPath: "/tmp"),
            auth: YouTubeAuth(), chain: ["default"])
        #expect(mp3Args.contains("--embed-thumbnail"))
    }

    @Test func thumbnailResidueCandidates() throws {
        let dir = try TestHelpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func touch(_ name: String, mtime: Date? = nil) throws {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
            if let mtime {
                try FileManager.default.setAttributes(
                    [.modificationDate: mtime],
                    ofItemAtPath: dir.appendingPathComponent(name).path)
            }
        }
        // Fixed clock: old files predate `since`, run-born files postdate it.
        // (Wall-clock `Date()` between touches races FS mtime granularity.)
        let since = Date(timeIntervalSince1970: 1_750_000_000)
        let output = dir.appendingPathComponent("01 - Title [abc123].wav")
        try Data("audio".utf8).write(to: output)
        // Predates the run: user-placed or ancient residue — must survive.
        try touch("01 - Title [abc123].png", mtime: since.addingTimeInterval(-3600))
        try touch("cover.jpg", mtime: since.addingTimeInterval(-3600))
        try touch("01 - Title [abc123].txt", mtime: since.addingTimeInterval(-3600))
        try touch("02 - Other [zzz].jpg", mtime: since.addingTimeInterval(-3600))
        // Born during the run: yt-dlp residue — must be listed.
        try touch("01 - Title [abc123].jpg", mtime: since.addingTimeInterval(10))
        try touch("01 - Title [abc123].webp", mtime: since.addingTimeInterval(10))
        let found = YTDLPService.thumbnailResidueCandidates(output: output, in: dir, since: since)
            .map(\.lastPathComponent).sorted()
        #expect(found == ["01 - Title [abc123].jpg", "01 - Title [abc123].webp"])

        // Uppercase extensions match too. Separate dir: default APFS is
        // case-insensitive, so same-stem upper/lower variants would collide.
        let dir2 = try TestHelpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let output2 = dir2.appendingPathComponent("03 - Upper [u].wav")
        try Data("audio".utf8).write(to: output2)
        try Data("x".utf8).write(to: dir2.appendingPathComponent("03 - Upper [u].JPG"))
        try FileManager.default.setAttributes(
            [.modificationDate: since.addingTimeInterval(10)],
            ofItemAtPath: dir2.appendingPathComponent("03 - Upper [u].JPG").path)
        let found2 = YTDLPService.thumbnailResidueCandidates(output: output2, in: dir2, since: since)
            .map(\.lastPathComponent)
        #expect(found2 == ["03 - Upper [u].JPG"])
    }

}
