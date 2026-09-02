#!/bin/sh
# Build Plat.app from the SwiftPM executable.
#
# SwiftPM produces a bare binary; a SwiftUI app needs a bundle around it before
# macOS will give it a menu bar, a Dock tile and a normal activation policy.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG=${CONFIG:-release}
APP="$DIR/build/Plat.app"
VERSION=$(cat "$DIR/Version")
# "-" is an ad-hoc signature: fine locally, but a downloaded copy stays
# quarantined.  `make release` passes a Developer ID instead.
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:--}
if [ "$CODESIGN_IDENTITY" = "-" ]; then
	SIGN_OPTS=""
else
	SIGN_OPTS="--options runtime --timestamp"
fi

swift build --package-path "$DIR" -c "$CONFIG"
BIN=$(swift build --package-path "$DIR" -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Plat" "$APP/Contents/MacOS/Plat"

# Build AppIcon.icns from the 1024x1024 master.  macOS wants ten sizes; sips
# does the resampling and iconutil packs them.
ICON_SRC="$DIR/icons/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
	SET=$(mktemp -d)/AppIcon.iconset
	mkdir -p "$SET"
	for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
	            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
	            "512 512x512" "1024 512x512@2x"; do
		px=${pair%% *}; nm=${pair#* }
		sips -z "$px" "$px" "$ICON_SRC" --out "$SET/icon_$nm.png" >/dev/null 2>&1
	done
	iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
	rm -rf "$(dirname "$SET")"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>              <string>Plat</string>
	<key>CFBundleDisplayName</key>       <string>Plat</string>
	<key>CFBundleExecutable</key>        <string>Plat</string>
	<key>CFBundleIconFile</key>          <string>AppIcon</string>
	<key>CFBundleIdentifier</key>        <string>org.borman.Plat</string>
	<key>CFBundlePackageType</key>       <string>APPL</string>
	<key>CFBundleSignature</key>         <string>????</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<!-- Without NSPrincipalClass, LaunchServices does not treat a hand-made
	     bundle as a real AppKit app and can refuse to launch it into the Aqua
	     session (open -a fails with -600). -->
	<key>NSPrincipalClass</key>          <string>NSApplication</string>
	<key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key>           <string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>    <string>14.0</string>
	<key>NSHighResolutionCapable</key>   <true/>
	<key>NSDesktopFolderUsageDescription</key>
	<string>Plat measures the size of folders you choose.</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>Plat measures the size of folders you choose.</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>Plat measures the size of folders you choose.</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>Plat measures the size of folders you choose.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force $SIGN_OPTS --sign "$CODESIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, signed by ${CODESIGN_IDENTITY})"

# Install into ~/Applications so LaunchServices treats it as a real app.
if [ "$1" = "--install" ]; then
	# ~/Applications is indexed by LaunchServices and needs no admin rights.
	# Override with DESTDIR=/Applications to install for all users.
	DESTROOT=${DESTDIR:-$HOME/Applications}
	mkdir -p "$DESTROOT"
	DEST="$DESTROOT/Plat.app"
	rm -rf "$DEST"
	ditto "$APP" "$DEST"
	codesign --force $SIGN_OPTS --sign "$CODESIGN_IDENTITY" "$DEST"
	LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
	"$LSR" -f -R "$DEST" 2>/dev/null || true
	echo "Installed $DEST"
fi
