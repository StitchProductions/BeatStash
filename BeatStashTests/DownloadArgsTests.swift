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

}
