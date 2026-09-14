# Third-Party Notices (BeatStash)

BeatStash bundles the following tools — no Homebrew or separate install needed.
`yt-dlp` additionally self-updates from inside the app (Settings → Update,
or automatically on launch) into `~/Library/Application Support/BeatStash/bin/`.

## yt-dlp
- Source: https://github.com/yt-dlp/yt-dlp
- License: The Unlicense (public domain). See `https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE`.
- Usage: video/audio extraction, playlist probing, format merging.
- Update: in-app Settings → Check/Update (stable channel default, nightly
  opt-in), or automatic on launch. Manual builds at
  `https://github.com/yt-dlp/yt-dlp-nightly-builds/releases`.

## FFmpeg / FFprobe
- Source: https://ffmpeg.org
- License: GPL v2+/v3 or LGPL v2.1+ depending on build. Static macOS builds
  (e.g. evermeet.cx) note their configuration in `ffmpeg -version`.
- Usage: audio transcode (WAV/FLAC/MP3/Opus), thumbnail embed, tag post-pass.
- If you distribute BeatStash with FFmpeg binaries, include this notice
  and comply with the applicable GPL/LGPL source-offer requirements.

## Deno (optional, v1.1 PO-token support)
- Source: https://deno.com, MIT license. Listed as a yt-dlp dependency
  via Homebrew for YouTube proof-of-origin challenges.

## bgutil-ytdlp-pot-provider (optional plugin, not bundled)
- Source: https://github.com/Brainicism/bgutil-ytdlp-pot-provider
- License: see upstream repo. Drop into `Vendor/plugins/` (staged to
  `BeatStash/Resources/plugins/`) to enable automatic PO-token generation
  for SABR-gated formats. Requires Deno or Node (`brew install deno`).
  Without it BeatStash falls back to player clients that need no token.
