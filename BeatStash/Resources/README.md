# Resources/bin — bundled yt-dlp + ffmpeg (gitignored binaries)

This folder holds executable `yt-dlp`, `ffmpeg`, `ffprobe` staged by
`scripts/setup-binaries.sh` (copies from `Vendor/bin/`).

- Binaries are **not committed** (large, platform-specific).
- At runtime `BinaryManager` searches:
  1. Settings custom override (user-managed)
  2. `~/Library/Application Support/BeatStash/bin/` (self-updating copy)
  3. `BeatStash.app/Contents/Resources/bin/` (this snapshot)
  4. `/opt/homebrew/bin`, `/usr/local/bin`, `PATH` (last-resort fallback)
- Updates download from GitHub into Application Support — the bundle copy is
  never modified in place (it would break the code signature).
- Refresh the snapshot before release: `scripts/setup-binaries.sh --force`
  (`--channel nightly` to ship a nightly).
- Release DMG: run `scripts/setup-binaries.sh` with **static** builds before archiving,
  then deep-sign `Contents/Resources/bin/*` with `--options runtime`.
