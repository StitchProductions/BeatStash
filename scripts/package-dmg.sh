#!/bin/sh
# BeatStash — build the Release app and package a drag-and-drop DMG.
#
# Usage:
#   scripts/package-dmg.sh [--version 1.0.0] [--no-build] [--open]
#
# - Builds BeatStash.app with xcodebuild (Release) unless --no-build.
# - Stages BeatStash.app + an /Applications symlink into a folder and
#   compresses it with hdiutil into dist/BeatStash-<version>.dmg.
# - The app is ad-hoc signed ("Sign to Run Locally"): on first launch on
#   another Mac, right-click the app → Open to pass Gatekeeper.
set -eu

# Single source of truth for the release version is MARKETING_VERSION in
# BeatStash.xcodeproj (Info.plist + sidebar footer read it at runtime).
# Keep this default in sync on version bumps, or pass --version explicitly.
VERSION="1.0.0"
BUILD=1
OPEN_DMG=0
prev=""
for arg in "$@"; do
  if [ "$prev" = "--version" ]; then VERSION="$arg"; prev=""; continue; fi
  case "$arg" in
    --version=*) VERSION="${arg#--version=}" ;;
    --version) prev="--version" ;;
    --no-build) BUILD=0 ;;
    --open) OPEN_DMG=1 ;;
    -h|--help)
      echo "usage: $0 [--version 1.0.0] [--no-build] [--open]"
      exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-stage"
DMG="$DIST/BeatStash-${VERSION}.dmg"
APP_NAME="BeatStash.app"

if [ "$BUILD" -eq 1 ]; then
  echo "== Building $APP_NAME (Release) =="
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcodebuild -project "$ROOT/BeatStash.xcodeproj" \
      -scheme BeatStash -configuration Release \
      -destination 'platform=macOS' \
      BUILD_DIR="$DIST/build" \
      build
fi

BUILT_APP="$(find "$DIST/build" -maxdepth 4 -name "$APP_NAME" -type d | head -1)"
if [ -z "${BUILT_APP:-}" ]; then
  echo "error: $APP_NAME not found under $DIST/build (build first or drop --no-build)" >&2
  exit 1
fi
echo "Using app: $BUILT_APP"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" "$DIST"
cp -R "$BUILT_APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

echo "== Creating $DMG =="
hdiutil create -volname "BeatStash ${VERSION}" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "Done: $DMG"
ls -lh "$DMG"
if [ "$OPEN_DMG" -eq 1 ]; then open "$DMG"; fi
