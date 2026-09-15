# BeatStash

![BeatStash](docs/BeatStash.jpeg)

Turn YouTube links and Spotify playlists into a tagged local music library — on your Mac. No accounts, no API keys: everything it talks to is a free public API.

![CI](https://github.com/StitchProductions/BeatStash/actions/workflows/ci.yml/badge.svg)
![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue.svg)
![Release](https://img.shields.io/github/v/release/StitchProductions/BeatStash)

## Screenshots

| New Batch | Queue |
|---|---|
| ![New Batch](docs/screenshots/new-batch.png) | ![Queue](docs/screenshots/queue.png) |

| History | Spotify |
|---|---|
| ![History](docs/screenshots/history.png) | ![Spotify](docs/screenshots/spotify.png) |

| Settings |
|---|
| ![Settings](docs/screenshots/settings.png) |

## What it does

- **New Batch** — paste YouTube links or bare video IDs (one per line, comma- or space-separated), probe them, then Fetch info or Download. Playlists, Shorts, and single videos supported.
- **Queue** — live progress, speed/ETA, cancellation, and automatic re-queue of transient failures.
- **History** — everything you've downloaded, with metadata and artwork.
- **Spotify** — paste a public Spotify playlist or track link; BeatStash resolves each song's title, artist, artwork, and duration (Spotify + Deezer, no login) in seconds, then hands them to New Batch as YouTube searches that grab the first result. No Spotify API key needed — review drafts by eye before downloading.
- **Settings** — audio format (Opus, M4A, MP3 320, FLAC, WAV), yt-dlp update channel (stable/nightly), cookies/browser auth, IPv4, and library location.
- Downloads are tagged (artist/title/album/track/year/genre + cover art) via an ffmpeg post-pass and land in your library folder, ready for any DAW or player.

## Install

1. Download `BeatStash-1.0.0.dmg` from the [releases page](https://github.com/StitchProductions/BeatStash/releases).
2. Open it and drag **BeatStash** into **Applications**.
3. First launch: right-click the app → **Open** (the app is ad-hoc signed, so Gatekeeper asks once), agree to automatic yt-dlp updates, and you're in.

Requires macOS 15 or later. Everything needed (yt-dlp, ffmpeg, ffprobe) ships inside the app — nothing else to install.

## Build from source

```sh
git clone https://github.com/StitchProductions/BeatStash.git
cd BeatStash
scripts/setup-binaries.sh        # fetches yt-dlp + ffmpeg/ffprobe into Vendor/ and stages them for Xcode
open BeatStash.xcodeproj         # or: xcodebuild test -scheme BeatStash -destination 'platform=macOS'
```

Make a release DMG:

```sh
scripts/package-dmg.sh --version <version>   # → dist/BeatStash-<version>.dmg
```

## Tests

100+ tests (`BeatStashTests/`), run on every push via GitHub Actions — see the badge above. Run them locally:

```sh
xcodebuild test -scheme BeatStash -destination 'platform=macOS'
```

Suites cover URL/Spotify-link parsing, tag parsing, handoff search URLs, probe-error classification and retry chains, download argument building, auth/client chains, oEmbed shapes, and version comparison. A headless end-to-end smoke test lives in `scripts/smoke-test.sh`.

## Credits

BeatStash stands on excellent open-source work — thank you:

**Bundled tools**

- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** (The Unlicense) — video/audio extraction, playlist probing, format merging. Bundled in the app and self-updated from Settings.
- **[FFmpeg / FFprobe](https://ffmpeg.org)** (GPL/LGPL depending on build) — audio transcoding, thumbnail embedding, tag post-pass.
- **[Deno](https://deno.com)** (MIT, optional) — JS runtime for YouTube proof-of-origin challenges.
- **[bgutil-ytdlp-pot-provider](https://github.com/Brainicism/bgutil-ytdlp-pot-provider)** (optional, not bundled) — automatic PO-token generation; drop into `Vendor/plugins/`.

**Free web APIs (no keys, no accounts)**

- **YouTube** — extraction and search via yt-dlp, plus oEmbed for instant titles.
- **Spotify** — public playlist pages and oEmbed for track metadata.
- **Deezer** — search anchor for durations and album names.
- **GitHub API** — yt-dlp + BeatStash release checks behind both self-updaters.

Full license details in [Third-Party-Notices.md](Third-Party-Notices.md). If you redistribute BeatStash with FFmpeg binaries, honor the applicable GPL/LGPL source-offer requirements noted there.

Made with 💚 by Stitch — and made possible by yt-dlp.
