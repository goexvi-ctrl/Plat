# dmgbuild settings for the Plat release disk image.
#
# Used by scripts/macos-release.sh:
#   APP=... BG=... dmgbuild -s scripts/dmg/settings.py "<VolName>" out.dmg
#
# One row: Plat.app on the left, an Applications symlink on the right, over a
# background with an arrow running from one to the other. dmgbuild writes the
# .DS_Store itself, so no Finder or GUI session is needed and this works over
# ssh and in CI.
#
# Icon centres are window-content points and must stay in step with the layout
# constants in make-background.sh.

import os

app = os.environ["APP"]   # path to the built (signed) Plat.app
bg = os.environ["BG"]     # background .tiff carrying the 1x and 2x images

appname = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}

background = bg
default_view = "icon-view"
window_rect = ((200, 150), (560, 380))   # ((x, y), (width, height))
icon_size = 96
text_size = 12
show_status_bar = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_locations = {
    appname:        (150, 200),
    "Applications": (410, 200),
}
