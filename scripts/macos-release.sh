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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DMG_ASSETS="$SCRIPT_DIR/dmg"

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

# 2. Build a styled disk image with dmgbuild: the app, an Applications symlink
#    to drag it onto, and a background with an arrow from one to the other, so
#    no README is needed. dmgbuild writes the .DS_Store directly, so no Finder
#    or GUI session is involved.
#
#    dmgbuild is a Python tool; use it from PATH if present, otherwise
#    provision it into a local venv (python3 ships with the command line tools
#    that a Swift build already needs).
DMGBUILD="$(command -v dmgbuild || true)"
if [ -z "$DMGBUILD" ]; then
	VENV="$BUILD_DIR/dmgbuild-venv"
	if [ ! -x "$VENV/bin/dmgbuild" ]; then
		echo "macos-release: provisioning dmgbuild into $VENV"
		python3 -m venv "$VENV"
		"$VENV/bin/pip" install --quiet --upgrade pip
		"$VENV/bin/pip" install --quiet dmgbuild
	fi
	DMGBUILD="$VENV/bin/dmgbuild"
fi

# Combine the 1x and 2x backgrounds into one Retina-aware TIFF.
BG_TIFF="$BUILD_DIR/dmg-background.tiff"
tiffutil -cathidpicheck \
	"$DMG_ASSETS/dmg-background.png" "$DMG_ASSETS/dmg-background@2x.png" \
	-out "$BG_TIFF" >/dev/null

rm -f "$DMG"
APP="$APP" BG="$BG_TIFF" "$DMGBUILD" -s "$DMG_ASSETS/settings.py" "$VOLNAME" "$DMG"
rm -f "$BG_TIFF"

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
