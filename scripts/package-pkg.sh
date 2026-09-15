#!/bin/sh
# BeatStash — build the Release app and package a drag-free installer PKG.
#
# Usage:
#   scripts/package-pkg.sh [--version 1.0.0] [--no-build]
#
# - Builds BeatStash.app with xcodebuild (Release) unless --no-build
#   (shares dist/build with package-dmg.sh, so run either first).
# - Wraps BeatStash.app with pkgbuild, installing to /Applications, into
#   dist/BeatStash-<version>.pkg.
# - Like the DMG, the payload is ad-hoc signed ("Sign to Run Locally"): on
#   first install on another Mac, right-click the .pkg → Open to pass
#   Gatekeeper.
set -eu

# Single source of truth for the release version is MARKETING_VERSION in
# BeatStash.xcodeproj (Info.plist + sidebar footer read it at runtime).
# Keep this default in sync on version bumps, or pass --version explicitly.
VERSION="1.0.0"
BUILD=1
prev=""
for arg in "$@"; do
  if [ "$prev" = "--version" ]; then VERSION="$arg"; prev=""; continue; fi
  case "$arg" in
    --version=*) VERSION="${arg#--version=}" ;;
    --version) prev="--version" ;;
    --no-build) BUILD=0 ;;
    -h|--help)
      echo "usage: $0 [--version 1.0.0] [--no-build]"
      exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
PKG="$DIST/BeatStash-${VERSION}.pkg"
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

rm -f "$PKG"
echo "== Creating $PKG =="
pkgbuild --component "$BUILT_APP" \
  --install-location /Applications \
  "$PKG"

echo "Done: $PKG"
ls -lh "$PKG"
