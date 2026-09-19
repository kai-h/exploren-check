#!/bin/bash
# make-icns.sh — build AppIcon.icns from packaging/icon.png
#
# Generated at build time rather than committed, so the PNG stays the single
# source of truth and the .icns cannot drift from it.
#
# Usage: ./make-icns.sh <output.icns>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/icon.png"
OUT="${1:?usage: make-icns.sh <output.icns>}"

[[ -f "$SOURCE" ]] || { echo "No icon at $SOURCE" >&2; exit 1; }

# Built in /tmp for the same reason the app bundles are: iconutil is as fussy
# about stray Finder metadata as codesign is, and this repo lives under
# ~/Documents where a cloud sync integration adds it.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

# The sizes macOS actually asks for. Omitting any of them doesn't fail the
# build, it just makes the icon look soft at that size in the Dock or Finder.
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"
    name="${spec#*:}"
    sips -z "$px" "$px" "$SOURCE" --out "$ICONSET/icon_$name.png" >/dev/null 2>&1
done

iconutil -c icns "$ICONSET" -o "$OUT"
