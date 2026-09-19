#!/bin/bash
# build.sh — ad-hoc build for running it yourself.
#
# For a signed, notarised build to give to anyone else, use
# packaging/release.sh instead.
#
# Usage: ./build.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
VERSION="$(cat VERSION)"

# Assembled in /tmp, not in the repo. This repo lives under ~/Documents, where
# a File-Provider-based cloud sync integration stamps Finder metadata onto
# bundles as they are written. codesign refuses to sign a bundle carrying it
# ("resource fork, Finder information, or similar detritus not allowed"), and
# worse, re-stamping after a successful signing silently invalidates the
# signature. It is a race, so it fails intermittently and looks like something
# else entirely.
STAGE="/tmp/explorencheck-dev"
APP="$STAGE/ExplorenCheck.app"

# Run from ~/Applications rather than /tmp: an app needs a stable, trusted
# location for macOS to keep its notification permission, which is the whole
# reason the ad-hoc signature is here.
INSTALL_DIR="$HOME/Applications"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ExplorenCheck"

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ExplorenCheck"
packaging/make-icns.sh "$APP/Contents/Resources/AppIcon.icns"

# Build 0 marks an ad-hoc build, so a bug report from one is recognisable.
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/0/" \
    packaging/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc is enough to run locally, and is what makes notifications work at
# all. It is not enough for anyone else: Gatekeeper will refuse it.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR:?}/ExplorenCheck.app"
cp -R "$APP" "$INSTALL_DIR/"

echo "installed $INSTALL_DIR/ExplorenCheck.app (ad-hoc signed, $VERSION)"
echo "run it with:  open -b au.com.automatica.explorencheck"
