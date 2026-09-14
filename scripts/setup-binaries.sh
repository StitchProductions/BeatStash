#!/bin/sh
# BeatStash — fetch bundled binaries into Vendor/ + app Resources.
# - yt-dlp: standalone macOS binary (includes Python, Unlicense)
# - ffmpeg/ffprobe: static builds; prefer Homebrew on dev machines.
# Release packaging copies Vendor/bin/* → BeatStash.app/Contents/Resources/bin/
#
# Usage:
#   scripts/setup-binaries.sh [--force] [--channel stable|nightly]
#   YTDLP_CHANNEL=nightly scripts/setup-binaries.sh   # same effect as --channel
#
# - --force refreshes yt-dlp even when Vendor/bin/yt-dlp already exists.
# - --channel selects the yt-dlp release line (default: stable).
set -eu

FORCE=0
CHANNEL="${YTDLP_CHANNEL:-stable}"
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    --channel=*) CHANNEL="${arg#--channel=}" ;;
    -h|--help) echo "usage: $0 [--force] [--channel stable|nightly]"; exit 0 ;;
    nightly|stable) CHANNEL="$arg" ;;
    --channel)
      echo "usage: $0 [--force] [--channel stable|nightly]" >&2
      exit 2 ;;
    *) echo "unknown argument: $arg (usage: $0 [--force] [--channel stable|nightly])" >&2
      exit 2 ;;
  esac
done
# Support `--channel nightly` (two-word form).
prev=""
for arg in "$@"; do
  if [ "$prev" = "--channel" ]; then CHANNEL="$arg"; fi
  prev="$arg"
done
case "$CHANNEL" in
  stable) YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" ;;
  nightly) YTDLP_URL="https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp_macos" ;;
  *) echo "unknown channel: $CHANNEL (want stable|nightly)" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_BIN="$ROOT/Vendor/bin"
RES_BIN="$ROOT/BeatStash/Resources/bin"
mkdir -p "$VENDOR_BIN" "$RES_BIN"

echo "== BeatStash setup-binaries =="

# 1. yt-dlp (universal macOS binary, standalone — Python included, no brew needed)
if [ "$FORCE" -eq 1 ] || [ ! -x "$VENDOR_BIN/yt-dlp" ]; then
  echo "Downloading yt-dlp_macos (channel: $CHANNEL) ..."
  curl -L --fail "$YTDLP_URL" \
    -o "$VENDOR_BIN/yt-dlp"
  chmod +x "$VENDOR_BIN/yt-dlp"
else
  echo "yt-dlp already present, skipping (use --force to re-fetch)."
fi
xattr -cr "$VENDOR_BIN/yt-dlp" 2>/dev/null || true
codesign -s - --timestamp=none "$VENDOR_BIN/yt-dlp" 2>/dev/null || true

# 2. ffmpeg / ffprobe — UNIVERSAL binaries built with lipo from OSXExperts
#    static builds (verified SHA256 on 2026-09-09):
#      arm64: ffmpeg 591260c9…, ffprobe e11c17e8… (v9.0)
#      intel: ffmpeg df3f1e3f…, ffprobe 5228e651… (v8.0)
#    Fully static (only system frameworks) so they bundle portably.
#    yt-dlp_macos from GitHub is already universal — no lipo needed.
for tool in ffmpeg ffprobe; do
  if [ -x "$VENDOR_BIN/$tool" ] && lipo -info "$VENDOR_BIN/$tool" 2>/dev/null | grep -q "x86_64 arm64"; then
    echo "$tool already universal, skipping."
    continue
  fi
  case "$tool" in
    ffmpeg)
      arm_url="https://www.osxexperts.net/ffmpeg9arm.zip"
      intel_url="https://www.osxexperts.net/ffmpeg80intel.zip" ;;
    ffprobe)
      arm_url="https://www.osxexperts.net/ffprobe9arm.zip"
      intel_url="https://www.osxexperts.net/ffprobe80intel.zip" ;;
  esac
  echo "Downloading $tool (arm64 + intel static) ..."
  tmpdir="$(mktemp -d)"
  curl -L --fail "$arm_url" -o "$tmpdir/arm.zip"
  curl -L --fail "$intel_url" -o "$tmpdir/intel.zip"
  mkdir -p "$tmpdir/arm" "$tmpdir/intel"
  unzip -o -j "$tmpdir/arm.zip" -d "$tmpdir/arm"
  unzip -o -j "$tmpdir/intel.zip" -d "$tmpdir/intel"
  lipo -create "$tmpdir/arm/$tool" "$tmpdir/intel/$tool" -output "$VENDOR_BIN/$tool"
  chmod +x "$VENDOR_BIN/$tool"
  xattr -cr "$VENDOR_BIN/$tool" || true
  codesign -s - --timestamp=none "$VENDOR_BIN/$tool" || true
  rm -rf "$tmpdir"
done

# 3. Stage into Resources for Xcode copy phase / ad-hoc runs.
for tool in yt-dlp ffmpeg ffprobe; do
  if [ -f "$VENDOR_BIN/$tool" ]; then
    cp -f "$VENDOR_BIN/$tool" "$RES_BIN/$tool"
    chmod +x "$RES_BIN/$tool" || true
  fi
done

# 4. Optional yt-dlp plugins (e.g. PO-token provider). Drop *.py / packages
#    into Vendor/plugins/ — staged to Resources/plugins/ and passed via
#    --plugin-dirs only when a JS runtime (deno/node) is also installed.
mkdir -p "$ROOT/Vendor/plugins" "$ROOT/BeatStash/Resources/plugins"
if ls "$ROOT/Vendor/plugins"/* >/dev/null 2>&1; then
  cp -Rf "$ROOT/Vendor/plugins/." "$ROOT/BeatStash/Resources/plugins/"
  echo "Staged plugins: $(ls "$ROOT/BeatStash/Resources/plugins" | tr '\n' ' ')"
else
  echo "No plugins in Vendor/plugins (optional PO-token provider) — skipping."
fi

echo "Versions:"
"$VENDOR_BIN/yt-dlp" --version 2>/dev/null || echo "  yt-dlp: missing"
"${VENDOR_BIN}/ffmpeg" -version 2>/dev/null | head -1 || echo "  ffmpeg: missing"
echo "Done. Resources staged in BeatStash/Resources/bin/"
