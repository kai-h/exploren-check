#!/bin/bash
# release.sh — build, sign with Developer ID, notarise, staple, and package
# ExplorenCheck for distribution.
#
# The ad-hoc build from ../build.sh runs fine on the machine that made it and
# nowhere else: Gatekeeper refuses an ad-hoc signature. This is the one that
# other people can actually open.
#
# Prerequisites:
#   A "Developer ID Application" certificate in the login keychain
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#   cp .env.example .env   # then fill it in
#
# Usage:
#   ./packaging/release.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=.env.example
source "$SCRIPT_DIR/.env"

: "${TEAM_ID:?TEAM_ID not set — copy .env.example to .env and fill it in}"
: "${SIGN_ID:?SIGN_ID not set — copy .env.example to .env and fill it in}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE not set — copy .env.example to .env and fill it in}"

# Built outside the repo on purpose. This repo lives under ~/Documents, where a
# File-Provider-based cloud sync integration stamps Finder metadata onto freshly
# created bundles before codesign runs, and codesign then refuses to sign them
# ("resource fork, Finder information, or similar detritus not allowed").
# /tmp is not synced, so it does not happen there. Learned the expensive way on
# another app in this account; carried over rather than rediscovered.
BUILD_DIR="/tmp/explorencheck-release"
APP="$BUILD_DIR/ExplorenCheck.app"
DIST_DIR="$SCRIPT_DIR/dist"

VERSION="$(cat "$REPO_ROOT/VERSION")"

# CFBundleVersion has to increase for each release even when the marketing
# version does not. Bumped before any work so a failed run burns a number
# rather than reusing one.
COUNTER="$SCRIPT_DIR/BUILD_NUMBER"
BUILD=$(($(cat "$COUNTER" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$BUILD" > "$COUNTER"

# Named by marketing version alone. Including the build number read as
# semver to anyone looking at the release page: "0.1.1" for version 0.1
# build 1 collides with a genuine 0.1.1. The build number is still in
# CFBundleVersion, where it belongs.
ZIP="$BUILD_DIR/ExplorenCheck-$VERSION.zip"
DMG="$BUILD_DIR/ExplorenCheck-$VERSION.dmg"

# notarytool reports a rejected credential as a bare "HTTP status code: 401.
# Unauthenticated." naming neither which credential nor how to repair it. The
# app-specific password behind $NOTARY_PROFILE is invalidated whenever the
# Apple ID password changes, so this is a recurring failure, not an exotic one.
# Output is streamed as it arrives since --wait can sit for several minutes,
# while a copy is kept to test afterwards.
notarise() {
    local target="$1" log status
    log="$(mktemp)"
    set +e
    xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    set -e
    if [[ $status -ne 0 ]]; then
        if grep -qEi '401|Unauthenticated' "$log"; then
            cat >&2 <<EOF

------------------------------------------------------------------------
Notarisation was refused as unauthenticated, using keychain profile
'$NOTARY_PROFILE'. The obvious cause is not the usual one — work through
these in order:

  1. STALE KEYCHAIN ITEM. store-credentials reports success and saves
     happily while an older item under the same profile name keeps being
     the one that gets read. Store under a NEW name and test it:

       xcrun notarytool store-credentials "${NOTARY_PROFILE}2" \\
         --apple-id "${APPLE_ID:-<your-apple-id>}" --team-id "$TEAM_ID"
       xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}2"

     If that works, delete every notary item matching the old name in
     Keychain Access and store it again under the original name.

  2. REVOKED PASSWORD. Apple revokes every app-specific password on the
     account whenever the Apple ID password changes. Generate a new one at
     appleid.apple.com -> Sign-In and Security -> App-Specific Passwords.
     If step 1's fresh profile also 401s, the password is probably fine:
     store-credentials validates against Apple before saving.

  3. ACCOUNT LEVEL. An unaccepted Apple Developer Program agreement makes
     the notary service return a bare 401 without saying so. Check
     developer.apple.com/account for a banner.
------------------------------------------------------------------------
EOF
        fi
        rm -f "$log"
        exit $status
    fi
    rm -f "$log"
}

echo "==> Building $VERSION ($BUILD)"
cd "$REPO_ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/ExplorenCheck"

rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ExplorenCheck"
"$SCRIPT_DIR/make-icns.sh" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    "$SCRIPT_DIR/Info.plist" > "$APP/Contents/Info.plist"

echo "==> Signing"
# --options runtime is the hardened runtime, which notarisation requires and
# will reject the submission without. --timestamp is likewise required: an
# un-timestamped signature notarises but stops validating once the certificate
# expires. Neither failure is visible at signing time.
codesign --force --deep \
    --sign "$SIGN_ID" \
    --options runtime \
    --timestamp \
    "$APP"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarising"
# A plain zip cannot be stapled, so this one is only a transport for the
# submission. The ticket is stapled to the .app afterwards, and the archive
# that people download is built from the stapled bundle below.
ditto -c -k --keepParent "$APP" "$BUILD_DIR/submission.zip"
notarise "$BUILD_DIR/submission.zip"

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Checking Gatekeeper accepts it"
# The real test. Signing and notarising can both succeed while the result is
# still refused on another machine, and this is what that machine will run.
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Packaging"
mkdir -p "$DIST_DIR"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ZIP" "$DIST_DIR/"

# The DMG is a second, independent artefact: it is signed, notarised and
# stapled in its own right, not merely a container for an app that happens to
# be. Skipped rather than fatal when create-dmg is absent, since the zip above
# is already a complete release.
if command -v create-dmg >/dev/null; then
    echo "==> Building DMG"
    create-dmg \
      --volname "ExplorenCheck" \
      --window-size 540 380 \
      --icon-size 128 \
      --icon "ExplorenCheck.app" 140 190 \
      --app-drop-link 400 190 \
      --hide-extension "ExplorenCheck.app" \
      "$DMG" \
      "$APP"

    echo "==> Signing DMG"
    # Without this the DMG itself fails Gatekeeper with "no usable signature"
    # even though the app inside is notarised: spctl needs a signature on the
    # image to anchor its assessment to.
    codesign --sign "$SIGN_ID" --timestamp "$DMG"

    echo "==> Notarising DMG"
    notarise "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

    cp "$DMG" "$DIST_DIR/"
else
    echo "==> Skipping DMG (create-dmg not installed: port install create-dmg)"
fi

echo ""
echo "Done: $DIST_DIR/$(basename "$ZIP")"
[[ -f "$DMG" ]] && echo "      $DIST_DIR/$(basename "$DMG")"
echo "Both carry their own notarisation ticket, so they open without a"
echo "Gatekeeper prompt even offline."
