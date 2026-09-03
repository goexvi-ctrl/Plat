<img src="icons/AppIcon.png" alt="Plat Icon" width="128">

# Plat

A disk-usage treemap for macOS: scan a folder and every file becomes a rectangle
whose area is its size.  A *plat* is a surveyor's map of land divided into
parcels, drawn to scale, used to work out what a piece of ground is worth.
Plat does the same for your disk or folder.  You can also preview a file
without leaving Plat, drag a file to somewhere else, or move it to the Trash.

This is a rewrite in Swift of a Cocoa program written in 2004 that was
called SpaceMonger, after the Windows program of the same name.  We renamed
the program Plat to protect the innocent.

## Installing

Open the disk image and drag `Plat.app` onto the `Applications` folder beside
it.  The release is signed and notarized, so it opens straight away.

Requires macOS 14 or later, on Apple silicon.

## Your first scan

**File > Open Folder** (Cmd-O), pick a folder, and the map appears.

Scanning is fast.  A home folder of a million-odd files takes a few seconds.
You can also press **Cancel** to stop it scanning.

If the status bar reports files it could not read, macOS is withholding
folders such as Desktop, Documents and Downloads.  Grant Plat **Full Disk
Access** in System Settings > Privacy & Security and scan again.

## Getting around the map

Each box is a file or a folder.  A folder's box contains its contents, with the
folder's name and size along the top.

| | |
|---|---|
| **Click** a box or its title strip | Details for that file or folder |
| **Double-click** a box | Zoom in, so that folder fills the window |
| **Right-click** | Go back up one level |
| **Hover** | Name in a tooltip; full path and size in the status bar |
| **Space** | Quick Look the box under the pointer |
| **Delete** | Move it to the Trash, after a confirmation |
| **Drag a box out** | Copy or move the file to anywhere that takes files |
| **Cmd-Up** | Up one level |
| **Shift-Cmd-Up** | Back to the top |
| **Shift-Cmd-G** | Jump to a folder by name |
| **Shift-Cmd-B** | Open bundles up, or shut them again |
| **Cmd-Z** | Put back the last thing deleted |
| **Cmd-R** | Scan the same folder again |

The path in the toolbar shows where you are looking.  Initially it only has
the name of the folder you opened.  After zooming in it will show the sub-path
to what is currently being shown.  **Click any element of it to jump there.**
A path deeper than five levels folds its leading elements into a menu.

The details panel is set large enough to read at a glance.  It gives the size
both readably and in exact bytes, the kind of file, what the file actually
contains, how many items a folder holds directly and in total, and what share
of its parent and of the whole scan it accounts for.  **Click the name or the
path in the panel to copy it.**

There are buttons to **Quick Look** it, **Open** it in whatever application
handles it, **Reveal** it in the Finder, **Move it to the Trash**, and to zoom
in, along with a one-line verdict on how risky deleting it would be.  Quick
Look is the same system panel the Finder uses.  If the file was removed since
the scan the panel will say so.

## Reading the map

* **Coloured boxes are files.**  The colour comes from the file extension, so
  all the videos in a folder, or all the object files, read as one block.
* **Pale boxes with a title strip are folders** that have been opened up to
  show what is inside them.
* **Solid blue-grey boxes are folders that were not opened.**  There is more
  inside them than the map is showing.
* **A red triangle in a corner marks a hard link.**  See below; it matters.
* **A grey box reading "N smaller items"** stands in for a tail of files too
  small to draw individually.  Their space is still counted.

The **Aa** toggle in the toolbar turns the labels off, which gives the boxes
themselves more room.

## Applications and other bundles

A bundle -- an application, a Pages document, a sparse bundle, or anything else
macOS presents as a single object -- is drawn as a single box, with its whole
weight and a flat colour, exactly like a file.

**Double-click** a bundle to look inside it.  **Shift-Cmd-B**
(View > Treat Bundles as Single Files) opens them all up at once.

## Colours and fonts

**Plat > Settings** (Cmd-,) has two tabs.

*Colors* gives a well for each part of the map -- background, open folder,
unopened folder, the grouped-small-files block, the hard-link flag, box
outline, label text and hover highlight -- each labelled with what it actually
colours.

Below those, **file kinds**.  Every file takes the colour of its kind --
Application, Archive, Document, Executable, Image, Movie, Music, PDF,
Presentation, Text or Other -- and each has a well.  Kinds come from macOS's own
type database, so anything the system recognises is classified.  Each row shows
a few extensions from the open scan that land in that kind.

Two cases where Plat differs from a plain reading of Apple's table: an
interpreted program is the file you run, so `.py`, `.js` and `.sh` are
**Executable** while `.swift`, `.m` and `.c` stay **Text**; and the TypeScript
family (`.ts`, `.tsx`, `.mts`, `.cts`) is treated as Text, since `.ts` otherwise
resolves to an MPEG-2 transport stream and fills a source tree with "Movie".

**Pinned extensions** override the kind: pin `.swift` orange and `.m` blue
whatever their kinds say.  Type an extension with or without the leading dot, in
any case.  The dialog lists the extensions using the most space in the open
scan, each in the colour it has now, so clicking one pins it where it already
is.

*Fonts* sets the family and size of the labels drawn inside boxes, and the size
of the details panel.  A larger map font means a taller label strip, so fewer
boxes are big enough to open up and the map gets coarser.

## Scanning a whole volume

Point Plat at a volume's mount point -- `/`, or anything under `/Volumes` --
and the map represents the whole disk rather than just the files on it.  Two
extra blocks appear beside the folders:

* **Free space**, what you could still write.
* **Not scanned**, space the volume reports as in use that the walk did not
  see: other volumes sharing the same APFS container, snapshots, folders it was
  not permitted to read, and purgeable space.

Together with the files, those sum to exactly the volume's capacity, so the map
answers "my disk is full but I can only find half of it in files" instead of
leaving the gap invisible.

A large "Not scanned" usually means either many local snapshots
(`tmutil listlocalsnapshots /`) or a scan that could not read much of the disk.
It stays one block because macOS reports no size per snapshot.

### The Trash is not free space

Nothing in the Trash is free.  Those files still occupy the disk until the Trash
is emptied, and Plat counts them as used, because `statfs` does.

Where they *appear* depends on whether the scan can read them:

* **Your own Trash**, `~/.Trash`, is an ordinary folder that only you can read
  -- and you are the one running Plat, so a scan of `/` or of your home folder
  walks it like any other folder and itemises what is in there.
* **A volume's Trash**, `/Volumes/<name>/.Trashes/<uid>`, sits inside a
  directory that is not listable, so those bytes land in **Not scanned** along
  with everything else the walk could not reach.

This is why deleting something in Plat does not make the free-space block grow.
The file has moved, not gone: the folder it was in shrinks, the Trash grows by
the same amount, and free space does not move until you empty the Trash.

Scanning a folder rather than a volume adds nothing; there is no capacity to
report.

## What "size" means

This is the part worth understanding, because the whole point of the program is
working out what you would actually get back by deleting something.

**Size on disk** (the default) is the space a file really occupies.  This is
what you free by deleting it, and it is what `du` reports.

**Logical size** is the file's apparent length -- what Finder calls "Size".

They are usually close, and occasionally wildly different.  A 500 GB sparse
disk image may occupy 4 KB.  Scaled by logical size, one such file swamps
everything real on the map, which is why on-disk is the default.  Switch
between them with the **Measure** menu in the toolbar; both are measured during
the scan, so switching is instant and needs no rescan.  The details panel
always shows both, and says outright when a file is sparse or compressed.

## Hard links

A hard link is one file reachable under several names.  **Deleting one of those
names frees nothing** -- the space goes only when the last name goes.  For a
program you are using to reclaim space, that is important to know, so Plat
flags every hard-linked file with a red triangle in its corner, warns in the
status bar when you hover one, spells out the link count in the details panel,
and shows a running total in the status bar.

**View > Split Hard-Linked Space** (on by default) divides a file's space
evenly among its names, so five links to a 1 MB file are charged 200 KB each.
Totals then match the space actually in use.  Turn it off to see each name
charged the full amount.

This applies to on-disk sizes only.  A file's apparent length does not depend
on how many names point at it, so Logical size is never divided.

## Deleting things

Finding the space is only half of it.  Point at a box and press **Delete**, or
use **Move to Trash** in the details popover.  It works from Quick Look too:
look at a file, decide it is junk, and press Delete without dismissing the
preview first.

Nothing is ever unlinked.  Items go to the Trash, and **Cmd-Z** puts the last
one back -- on disk and on the map.  The map updates immediately and without a
rescan: the box disappears, every folder above it shrinks, and the bytes are
charged to the Trash, which is where they now are.  Free space does not move
until the Trash is emptied, and Plat does not pretend otherwise -- see
[The Trash is not free space](#the-trash-is-not-free-space).

### The warning you get first

Before anything moves, Plat says how risky it thinks the delete is.  Because
everything goes to the Trash, this is not a scale of how much would be *lost* --
almost anything in the Trash can be dragged back.  What it grades is whether the
delete will quietly fail, whether something you are running will break, and
whether the deletion escapes this Mac.

| Verdict | Meaning | Examples |
| --- | --- | --- |
| **Safe to delete** | Regenerated on demand | `~/Library/Caches`, `~/Library/Logs`, `DerivedData`, `node_modules`, `.build` |
| **Goes to the Trash** | An ordinary file | anything in `~/Documents`, `~/Downloads` |
| **Check before deleting** | Nothing breaks, but something has to be reinstalled or set up again | an application, `~/Library/Application Support`, `~/Library/Preferences` |
| **Deleting this is risky** | Software will probably break, or the deletion reaches other devices | files inside an `.app`, `/opt/homebrew`, `LaunchDaemons`, iCloud Drive, `.git`, keychains |
| **Cannot be deleted** | The system will refuse | anything protected by System Integrity Protection, locked files, folders you cannot write to |

Four of these are worth knowing about in their own right:

* **Inside a bundle.**  Deleting one file out of `Thing.app` invalidates its
  code signature, and macOS will then usually refuse to launch it -- with an
  error that never mentions the missing file.  The same goes for a
  `.photoslibrary` or a `.pages` document.
* **Running right now.**  If the item belongs to an application that is running,
  the verdict is raised and names it.
* **Permissions.**  Removing an item needs write permission on the folder that
  contains it, not on the item.  This is the usual reason a delete fails with no
  explanation.
* **iCloud.**  Anything under `~/Library/Mobile Documents` is removed from every
  device signed in to the same account, and this Mac's Trash will not bring it
  back on the others.  Files evicted to iCloud free no space here at all.

### Answering it

**Y** deletes.  Any other key closes the box.

Nothing is bound to Return, deliberately: Return, Escape and every wrong guess
all cancel.  The buttons work too.  The box stays short for an ordinary delete
and spells out its reasons only when there is something to be careful about.

Plat asks before every delete.  Turning that off in **Settings > General** skips
the question for ordinary files only; anything risky still asks.

## Tooltips

Hover over a box and its name appears after the usual delay.  Just the name; the
status bar already has the full path and the size.  For a box too small to fit
its label, which is most of them on a full disk, this is the only thing that
says what it is.

While the tooltip is up it follows the pointer and changes the moment the
pointer crosses into another box, with no second wait.

## Looking at a file

Press **Space** over a box to Quick Look it -- the same preview the
Finder gives, in the same system panel.  A capacity block has no file to
preview, and neither does a name whose file has since been deleted; those show
the details popover instead.

**Delete** works while the preview is still up: look at a file, decide it is
junk, and it goes -- the preview closes and the confirmation takes its place.
Space closes the preview, as usual.

The details popover reports what the file actually contains, from `file(1)`:

    Kind      PNG image
    Contents  PNG image data, 1024 x 1024, 8-bit/color RGBA, non-interlaced

**Kind** comes from the extension, **Contents** from the first bytes on disk, so
the two disagree when a file has the wrong name.

## Dragging things out

Drag a box out of Plat and it behaves like a file, because it is one.  Drop it on
a Finder window, into a mail message, onto a terminal, anywhere that takes a
file.  The drag carries a real file URL and the file's own icon.

* **Dropping on the Finder** copies or moves it, following the usual rules and
  the usual modifier keys.
* **Dropping on the Trash** deletes it, and Plat notices.
* **Anything Plat calls risky** -- a file inside an application bundle, a
  startup item, iCloud Drive -- is offered for **copying only**, since a drag
  has nowhere to put a warning.  The Finder shows a copy badge rather than a
  move one.

A drag that really moves a file leaves the map correct: the folder it was in
shrinks.  Free space does not change, because a file moved elsewhere on the same
disk frees nothing.

Dropping a box on another box, to move a file inside the map, is not supported.

## Jumping to a folder by name

**Shift-Cmd-G** opens a search field.  Type a folder name and the map goes
there.  Nothing is re-read from disk; this searches the scan already in memory.

* A bare name matches anywhere: `node_modules`.
* A path fragment narrows it: `src/Alpha` will not match `docs/Alpha`.
* A full path, absolute or relative, goes straight there.
* Matching ignores case and matches parts of names, so `mod` finds
  `node_modules`.
* Results are ordered largest first, which is almost always the one you want.
* Arrow keys move the selection without leaving the field; Return goes.

## Showing fewer levels

Deeply nested folders can bury what you are looking for.  The **depth** control
in the toolbar caps how many levels are drawn: type a number, type `All` (or
leave it blank), or use the stepper.  **Cmd-]** and **Cmd-[** step one level
deeper or shallower, **Shift-Cmd-]** goes back to all levels.

Folders cut off by the limit are drawn as solid blocks, so you can still see
that there is something inside them.

## Choosing the layout

**Squarified** (the default) keeps boxes close to square, which makes areas
easy to compare and leaves room for labels.

**Classic (2004)** reproduces the original program's layout, long thin slivers
and all.  It is there because some people liked it.

## What is not counted

* **Symbolic links** are not followed and contribute nothing, so nothing is
  counted twice and no link loop can trap the scan.
* **Other volumes** are skipped.  A scan stays on the disk it started on.
* **Firmlink duplicates** are counted once.  `/Users` and
  `/System/Volumes/Data/Users` are the same directory reached two ways, so a
  scan of `/` would otherwise meet most of the disk twice.  Plat keeps the
  familiar path and drops the duplicate.
* **A volume's `.Trashes`** cannot be listed, so what is in there shows up
  under "Not scanned" rather than as files.  `~/.Trash` is readable and is
  scanned normally.
* **Sockets, pipes and devices** are skipped; they occupy no meaningful space.
* **Folders themselves** are measured only by what they contain.  The few
  blocks a directory's own entries occupy are not counted, so a total can sit a
  hair under `du`.
* **APFS clones** -- files duplicated with copy-on-write -- are counted in
  full, once each, as `du` does.  Only the filesystem knows they are shared.

Hidden files and folders *are* included, at every level: `.git`, `.build`,
`.local` and the rest all show up.

## Building from source

Needs a Swift 6 toolchain; built and tested with Xcode 26.

    make            # build build/Plat.app
    make test       # 184 tests
    make install    # also install into ~/Applications
    make release    # build build/Plat-<version>-macos-<arch>.dmg
    make tag        # annotated tag v<version> for the current commit
    make push-tag   # push that tag to origin

The `Version` file is the single source of truth for the version.  The commit
hash, its date and whether the tree was dirty are read from git at build time
and stamped into `Info.plist`, where the About box reads them.

`make install` takes `DESTDIR=/Applications` to install for all users.  The
build also makes the icon from `icons/AppIcon.png`, the 1024x1024 master.

A local build is ad-hoc signed -- fine on the machine that built it, but a copy
downloaded from anywhere else stays quarantined.  For a release that opens with
no warnings, pass a Developer ID; the app is then signed with the hardened
runtime and a secure timestamp, and the image is notarized and stapled:

    make release \
      CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
      NOTARY_PROFILE=plat-notary

`NOTARY_PROFILE` names a profile stored with `xcrun notarytool
store-credentials`.

Cutting a release: bump `Version`, commit, `make release` with a Developer ID,
then `make tag` and `make push-tag`.  `make tag` refuses a dirty tree or a
version already tagged.

    Sources/PlatCore/    scanner, tree, treemap, renderer -- no AppKit
    Sources/PlatApp/     SwiftUI window, NSView host, model
    Sources/PlatBench/   benchmark and offscreen PNG renderer
    Tests/PlatCoreTests/ 184 tests

`plat-bench` scans a tree and reports timings, and can render a treemap
straight to a PNG without opening a window:

    plat-bench ~/src --render out.png --layout classic --size 1600x1000
