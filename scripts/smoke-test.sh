#!/bin/sh
# BeatStash smoke-test — headless checks that need no Xcode.
#
#   scripts/smoke-test.sh
#     Fast checks only: syntax, project lint, universal binaries (Intel +
#     Silicon), bundled binary smoke, build-phase simulation, Swift
#     spot-check suite (the Xcode BeatStashTests bundle owns the full contract).
#
#   BEATSTASH_LIVE_TESTS=1 scripts/smoke-test.sh
#     Additionally: yt-dlp self-heal download, live GitHub release lookup
#     (stable + nightly), live single-video probe with timing budget.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIVE="${BEATSTASH_LIVE_TESTS:-0}"
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT INT TERM

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
section() { echo "== $1 =="; }

# --- 1. syntax + project lint ---------------------------------------------
section "syntax"
if sh -n "$ROOT/scripts/setup-binaries.sh" && sh -n "$ROOT/scripts/smoke-test.sh"; then
  ok "script syntax"
else
  bad "script syntax"
fi
if plutil -lint "$ROOT/BeatStash.xcodeproj/project.pbxproj" >/dev/null; then
  ok "pbxproj lint"
else
  bad "pbxproj lint"
fi
if "$ROOT/scripts/setup-binaries.sh" --help >/dev/null 2>&1; then
  ok "setup --help"
else
  bad "setup --help"
fi

# --- 2. universal binaries (Intel + Silicon) -------------------------------
section "universal"
for d in "$ROOT/Vendor/bin" "$ROOT/BeatStash/Resources/bin"; do
  for tool in yt-dlp ffmpeg ffprobe; do
    if [ -x "$d/$tool" ] && lipo -info "$d/$tool" 2>/dev/null | grep -q "x86_64 arm64"; then
      ok "universal $tool ($(basename "$d"))"
    else
      bad "universal $tool ($(basename "$d"))"
    fi
  done
done
if v=$("$ROOT/BeatStash/Resources/bin/yt-dlp" --version 2>/dev/null); then
  ok "bundled yt-dlp runs ($v)"
else
  bad "bundled yt-dlp runs"
fi

# --- 3. build-phase simulation ---------------------------------------------
section "build-phase"
python3 - "$ROOT/BeatStash.xcodeproj/project.pbxproj" "$TMPDIR_WORK/phase.sh" <<'EOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'Bundle yt-dlp \+ ffmpeg.*?shellScript = "(.*?)";\n', src, re.S)
assert m, "phase not found"
open(sys.argv[2], "w").write(m.group(1).encode().decode("unicode_escape"))
EOF
run_phase() { # $1=src $2=dst
  SRCROOT="$1" TARGET_BUILD_DIR="$2" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="BeatStash.app/Contents/Resources" \
    sh "$TMPDIR_WORK/phase.sh" > "$TMPDIR_WORK/phase.log" 2>&1
}
# A: all present -> copies, logs versions, exit 0
mkdir -p "$TMPDIR_WORK/A/src/BeatStash/Resources/bin" "$TMPDIR_WORK/A/dst"
cp "$ROOT/BeatStash/Resources/bin/yt-dlp" "$ROOT/BeatStash/Resources/bin/ffmpeg" \
   "$ROOT/BeatStash/Resources/bin/ffprobe" "$TMPDIR_WORK/A/src/BeatStash/Resources/bin/"
if run_phase "$TMPDIR_WORK/A/src" "$TMPDIR_WORK/A/dst" \
    && grep -q "note:   yt-dlp 20" "$TMPDIR_WORK/phase.log" \
    && [ -x "$TMPDIR_WORK/A/dst/BeatStash.app/Contents/Resources/bin/yt-dlp" ]; then
  ok "phase: copy + version log"
else
  bad "phase: copy + version log"; tail -5 "$TMPDIR_WORK/phase.log"
fi
# C: ffmpeg missing -> hard error, exit != 0
mkdir -p "$TMPDIR_WORK/C/src/BeatStash/Resources/bin" "$TMPDIR_WORK/C/dst"
cp "$ROOT/BeatStash/Resources/bin/yt-dlp" "$TMPDIR_WORK/C/src/BeatStash/Resources/bin/"
if run_phase "$TMPDIR_WORK/C/src" "$TMPDIR_WORK/C/dst"; then
  bad "phase: missing ffmpeg fails build"
else
  if grep -q "^error:" "$TMPDIR_WORK/phase.log"; then
    ok "phase: missing ffmpeg fails build"
  else
    bad "phase: missing ffmpeg fails build"
  fi
fi

# --- 4. Swift spot-checks (Xcode suite owns the full contract) -------------
section "swift"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc missing — skipping swift checks"
else
  mkdir -p "$TMPDIR_WORK/swift"
  cp "$ROOT/BeatStash/Models/"*.swift "$ROOT/BeatStash/Services/"*.swift "$TMPDIR_WORK/swift/"
  cat > "$TMPDIR_WORK/swift/main.swift" <<'EOF'
import Foundation
@main struct Harness {
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print((cond ? "PASS" : "FAIL") + " " + name)
            if !cond { failures += 1 }
        }
        check("versions", BinaryManager.compareVersions("2026.08.19", "2026.08.30.232658") == .orderedAscending
            && BinaryManager.compareVersions("2026.08.19", "2026.08.19") == .orderedSame)
        check("urls", URLParser.extractURLs(from: "a https://youtu.be/dQw4w9WgXcQ, dQw4w9WgXcQ").count == 2)
        check("tags", TagParser.parse(title: "A - B (Official Video)", uploader: "UVEVO").title == "B")
        do {
            let e = try JSONDecoder().decode(PlaylistEntry.self,
                from: Data(#"{"id":"x","playlist_title":"L","playlist_index":1}"#.utf8))
            check("decode", e.playlistTitle == "L" && e.playlistIndex == 1)
        } catch { check("decode", false) }
        if case .botCheck = YTDLPService.classifyProbeError(stderr: "Sign in to confirm you're not a bot") {
            check("classify", true)
        } else { check("classify", false) }
        check("probe args", YTDLPService.probeBaseArgs(auth: YouTubeAuth(), chain: ["android"]).contains("--ignore-no-formats-error"))
        // tag-output builder shape for the art-attach check below
        if let artDir = ProcessInfo.processInfo.environment["BEATSTASH_ART_DIR"] {
            let targs = YTDLPService.tagOutputArgs(
                tags: TrackTags(artist: "A", title: "T", album: "Alb"),
                format: .mp3, artPath: artDir + "/cover.jpg")
            print("ARTBEGIN")
            for a in (["-y", "-i", artDir + "/in.mp3", "-i", artDir + "/cover.jpg"] + targs + [artDir + "/out.mp3"]) {
                print("A:" + a)
            }
            print("ARTEND")
        }
        // locate fast path via PATH shims (no bundle in CLI env)
        let t0 = Date()
        let found = await BinaryManager.shared.locate()
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "locate %.3fs found=%@", dt, found ? "yes" : "no"))
        check("locate resolves", found)
        check("locate fast (<2s)", dt < 2)
        // download args point postprocessing at the resolved ffmpeg
        let args = await YTDLPService().buildArguments(
            job: DownloadJob(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                             kind: .audio, displayTitle: "T"),
            directory: URL(fileURLWithPath: "/tmp"))
        if let i = args.firstIndex(of: "--ffmpeg-location"), i + 1 < args.count {
            check("ffmpeg-location dir", args[i + 1].hasSuffix("shim"))
        } else {
            check("ffmpeg-location present", false)
        }
        if failures > 0 { print("\(failures) FAILURES"); exit(1) }
        print("SWIFT SPOT-CHECKS DONE")
    }
}
EOF
  mkdir -p "$TMPDIR_WORK/shim"
  ln -sf "$ROOT/Vendor/bin/yt-dlp" "$TMPDIR_WORK/shim/yt-dlp"
  ln -sf "$ROOT/Vendor/bin/ffmpeg" "$TMPDIR_WORK/shim/ffmpeg"
  mkdir -p "$TMPDIR_WORK/art"
  export BEATSTASH_ART_DIR="$TMPDIR_WORK/art"
  if swiftc -parse-as-library -o "$TMPDIR_WORK/swift/spot" "$TMPDIR_WORK/swift/"*.swift 2>"$TMPDIR_WORK/swift/err.log" \
      && PATH="$TMPDIR_WORK/shim:$PATH" "$TMPDIR_WORK/swift/spot" > "$TMPDIR_WORK/swift/out.log" 2>&1; then
    if grep -q "^FAIL" "$TMPDIR_WORK/swift/out.log"; then
      bad "swift spot-checks"; grep "^FAIL" "$TMPDIR_WORK/swift/out.log"
    else
      ok "swift spot-checks"
    fi
  else
    bad "swift spot-checks"; head -10 "$TMPDIR_WORK/swift/err.log" "$TMPDIR_WORK/swift/out.log" 2>/dev/null
  fi
fi

# --- art attach (bundled ffmpeg executes the builder's exact args) ---------
section "art"
if grep -q "^ARTBEGIN$" "$TMPDIR_WORK/swift/out.log" 2>/dev/null \
    && "$ROOT/Vendor/bin/ffmpeg" -y -v error -f lavfi -i "sine=frequency=440:duration=2" \
        -c:a libmp3lame "$TMPDIR_WORK/art/in.mp3" \
    && "$ROOT/Vendor/bin/ffmpeg" -y -v error -f lavfi -i "testsrc=size=300x300:duration=1:rate=1" \
        -frames:v 1 "$TMPDIR_WORK/art/cover.jpg"; then
  set --
  in_art=0
  while IFS= read -r line; do
    case "$line" in
      ARTBEGIN) in_art=1 ;;
      ARTEND) in_art=0 ;;
      A:*)
        if [ "$in_art" = 1 ]; then set -- "$@" "${line#A:}"; fi
        ;;
    esac
  done < "$TMPDIR_WORK/swift/out.log"
  if [ "$#" -gt 0 ] && "$ROOT/Vendor/bin/ffmpeg" "$@" < /dev/null 2>/dev/null \
      && "$ROOT/Vendor/bin/ffprobe" -v error -show_streams \
          -of json "$TMPDIR_WORK/art/out.mp3" \
      | python3 -c "
import json, sys
streams = json.load(sys.stdin).get('streams', [])
audio = any(s.get('codec_type') == 'audio' for s in streams)
pic = any(s.get('disposition', {}).get('attached_pic') == 1 for s in streams)
assert audio and pic, 'need audio + attached_pic, got: ' + str(streams)
"; then
    ok "art attach (mp3 keeps audio + attached_pic)"
  else
    bad "art attach (mp3 keeps audio + attached_pic)"
  fi
else
  echo "(art check skipped — fixtures or builder output missing)"
fi

# --- 5. live (opt-in) -------------------------------------------------------
if [ "$LIVE" = "1" ]; then
  section "live"
  # B: self-heal download
  mkdir -p "$TMPDIR_WORK/B/src/BeatStash/Resources/bin" "$TMPDIR_WORK/B/dst"
  cp "$ROOT/BeatStash/Resources/bin/ffmpeg" "$ROOT/BeatStash/Resources/bin/ffprobe" \
     "$TMPDIR_WORK/B/src/BeatStash/Resources/bin/"
  if run_phase "$TMPDIR_WORK/B/src" "$TMPDIR_WORK/B/dst" \
      && "$TMPDIR_WORK/B/dst/BeatStash.app/Contents/Resources/bin/yt-dlp" --version >/dev/null 2>&1; then
    ok "phase: yt-dlp self-heal download"
  else
    bad "phase: yt-dlp self-heal download"
  fi
  # GitHub release lookup, both channels
  if tag=$(curl -s --max-time 20 https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])") && [ -n "$tag" ]; then
    ok "stable lookup ($tag)"
  else
    bad "stable lookup"
  fi
  if tag=$(curl -s --max-time 20 https://api.github.com/repos/yt-dlp/yt-dlp-nightly-builds/releases/latest \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])") && [ -n "$tag" ]; then
    ok "nightly lookup ($tag)"
  else
    bad "nightly lookup"
  fi
  # Single probe with timing budget (serial; parallel throttles — see probeAll docs)
  start=$(date +%s)
  if "$ROOT/Vendor/bin/yt-dlp" --force-ipv4 --socket-timeout 15 --retries 2 --extractor-retries 2 \
      --extractor-args "youtube:player_client=android,ios,tv" --ignore-no-formats-error \
      --dump-json --no-playlist --no-warnings \
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ" 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('title'), 'no title'; print('title:', d['title'][:40])"; then
    secs=$(( $(date +%s) - start ))
    if [ "$secs" -lt 60 ]; then ok "live probe (${secs}s)"; else bad "live probe (${secs}s > 60s)"; fi
  else
    bad "live probe"
  fi
  # oEmbed instant tier: official endpoint, sub-second budget
  start=$(date +%s)
  if title=$(curl -s --max-time 10 \
      "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=dQw4w9WgXcQ&format=json" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('title'), 'no title'; print(d['title'][:40])") \
      && [ -n "$title" ]; then
    secs=$(( $(date +%s) - start ))
    if [ "$secs" -lt 10 ]; then ok "live oembed (${secs}s)"; else bad "live oembed (${secs}s > 10s)"; fi
  else
    bad "live oembed"
  fi
  # Deezer anchor (keyless canonical metadata for import matching)
  if curl -s --max-time 10 "https://api.deezer.com/search?q=Luis%20Fonsi%20Despacito" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('total', 0) > 0 and d['data'][0].get('duration'), 'no hit'"; then
    ok "live deezer anchor"
  else
    bad "live deezer anchor"
  fi
  # MusicBrainz reachability is informational only (strict throttling/503s are
  # normal) — the client paces, backs off, and degrades silently by contract.
  if curl -s --max-time 20 -A "BeatStash/1.0 ( smoke-test )" \
      --get --data-urlencode "query=Despacito" --data-urlencode "fmt=json" \
      --data-urlencode "limit=1" "https://musicbrainz.org/ws/2/recording/" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('recordings'), d.get('error', 'no recordings')" 2>/dev/null; then
    echo "info: musicbrainz reachable"
  else
    echo "info: musicbrainz busy/unreachable (expected sometimes — client degrades)"
  fi
else
  echo "(live checks skipped — BEATSTASH_LIVE_TESTS=1 to include)"
fi

echo "----------------------------------------"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
