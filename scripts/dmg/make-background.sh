#!/bin/sh
# Regenerate the DMG background images.
#
#   scripts/dmg/make-background.sh
#
# Draws a title, a subtitle and a dashed arrow pointing from where the app icon
# sits to where the Applications symlink sits, producing dmg-background.png
# (1x, 560x380) and dmg-background@2x.png (1120x760).  Requires ImageMagick.
#
# The outputs are committed, so a release build needs only tiffutil (always
# present on macOS) and not ImageMagick.
#
# The icon centres below must stay in step with icon_locations in settings.py.
set -eu

cd "$(dirname "$0")"

BOLD="/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REG="/System/Library/Fonts/Supplemental/Arial.ttf"

# Layout in window points; keep in sync with settings.py.
W=560            # window width
H=380            # window height
ICON_Y=200       # centre line of both icons
APP_X=150        # app icon centre
DEST_X=410       # Applications symlink centre
ARROW_X0=214     # arrow tail
ARROW_X1=330     # arrow head base
ARROW_TIP=352    # arrow point

render() {
	s=$1
	out=$2
	m() { echo $(( $1 * s )); }

	magick -size "$(m $W)x$(m $H)" xc:white \
		-stroke "#9a9a9a" -strokewidth "$(m 5)" -fill none \
		-draw "stroke-dasharray $(m 11) $(m 9) line $(m $ARROW_X0),$(m $ICON_Y) $(m $ARROW_X1),$(m $ICON_Y)" \
		-stroke none -fill "#9a9a9a" \
		-draw "polygon $(m $ARROW_X1),$(m $((ICON_Y - 15))) $(m $ARROW_X1),$(m $((ICON_Y + 15))) $(m $ARROW_TIP),$(m $ICON_Y)" \
		-gravity north \
		-font "$BOLD" -pointsize "$(m 24)" -fill "#222222" -annotate "+0+$(m 30)" "Install Plat" \
		-font "$REG" -pointsize "$(m 13)" -fill "#666666" -annotate "+0+$(m 66)" \
		"Drag Plat onto the Applications folder" \
		-font "$REG" -pointsize "$(m 11)" -fill "#999999" -gravity south -annotate "+0+$(m 22)" \
		"A disk-usage treemap for macOS" \
		"$out"
	echo "wrote $out ($(m $W)x$(m $H))"
}

render 1 dmg-background.png
render 2 "dmg-background@2x.png"
