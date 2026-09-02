#!/bin/sh
# Build a signed macOS .dmg for release, and -- given a Developer ID identity --
# notarize and staple it so it passes Gatekeeper with no user fiddling.
#
# Invoked by `make release` with these variables in the environment:
#   APP            path to the built .app bundle       (e.g. build/Plat.app)
#   DMG            output disk image path
#   VOLNAME        mounted volume name                 (e.g. "Plat 1.0")
#   IDENTITY       codesign identity, or "-" for ad-hoc
#   NOTARY_PROFILE stored notarytool keychain profile  (Developer ID only)
#
# IDENTITY="-" : ad-hoc sign only; the image is NOT notarized (dev/local use),
#   so a downloaded copy stays quarantined and must be cleared by hand.
# IDENTITY="Developer ID Application: ..." : hardened-runtime sign the app,
#   sign the image, submit it to Apple's notary service, and staple the ticket
#   -- a download then opens with no quarantine workaround.
set -eu

: "${APP:?set APP}" "${DMG:?set DMG}" "${VOLNAME:?set VOLNAME}" "${IDENTITY:?set IDENTITY}"
NOTARY_PROFILE="${NOTARY_PROFILE:-plat-notary}"
BUILD_DIR="$(dirname "$DMG")"

# Hardened runtime and a secure timestamp need a real certificate; an ad-hoc
# signature supports neither, so only request them for a Developer ID build.
runtime=""
timestamp=""
if [ "$IDENTITY" != "-" ]; then
	runtime="--options runtime"
	timestamp="--timestamp"
else
	echo "macos-release: ad-hoc signing (no Developer ID) -- skipping notarization"
fi

# 1. Sign the bundle. --force replaces the ad-hoc signature swiftc and
#    make-app.sh leave behind. Plat links only system frameworks, so there is
#    no nested code to sign first and no entitlements to grant.
"$(dirname "$0")/check-identity.sh" "$IDENTITY"
if ! codesign --force $runtime $timestamp --sign "$IDENTITY" "$APP"; then
	cat >&2 <<'MSG'

codesign failed.  If the error was errSecInternalComponent, codesign found the
certificate but could not reach its private key.  That is an environment
problem, not a problem with the app.  The usual causes:

  * The shell has no access to the login keychain.  Run this from a Terminal
    in your own GUI login session -- not over ssh, and not from a tmux or
    screen session that was started before you logged in.
  * The keychain is locked:
        security unlock-keychain ~/Library/Keychains/login.keychain-db
  * You ran make under sudo, so codesign is looking at root's keychain
    rather than yours.  Do not use sudo; use DESTDIR if you need to install
    somewhere privileged.
  * The private key's access control does not permit codesign.  In Keychain
    Access, find the "Developer ID Application" key, Get Info > Access
    Control, and allow codesign to use it.

Check what is visible to this shell with:
        security find-identity -v -p codesigning
MSG
	exit 1
fi
codesign --verify --strict --verbose=1 "$APP"

# 2. Stage the image: the app, plus an /Applications symlink to drag it onto.
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" \
	-ov -format UDZO "$DMG"
rm -rf "$STAGE"

# 3. Sign the disk image itself.
codesign --force $timestamp --sign "$IDENTITY" "$DMG"

# 4. With a Developer ID, notarize the image and staple the ticket, so the
#    check works offline and the first launch is silent.
if [ "$IDENTITY" != "-" ]; then
	echo "macos-release: submitting to the notary service (this can take a few minutes)..."
	xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
	spctl --assess --type open --context context:primary-signature -v "$DMG" || true
fi

echo "Wrote $DMG"
