<img src="icons/AppIcon.png" alt="Plat Icon" width="128">

# Plat

A disk-usage treemap for macOS: scan a folder and every file becomes a rectangle
whose area is its size.  A *plat* is a surveyor's map of land divided into
parcels, drawn to scale, used to work out what a piece of ground is worth --
which is exactly what this draws, and what you use it for.

This is a rewrite in Swift of a Cocoa program written in 2004 that was
called SpaceMonger, after the Windows program of the same name.  We renamed
the program Plat to protect the innocent.

## Installing

Open the disk image and drag `Plat.app` onto the `Applications` folder beside
it.  The release is signed and notarized, so it opens straight away.

Requires macOS 14 or later, on Apple silicon.

## Your first scan

**File > Open Folder** (Cmd-O), pick a folder, and the map appears.  Your home
folder is the usual starting point.  You can also launch it from a shell with a
path:

    Plat ~/Documents

Scanning is fast -- a home folder of a million-odd files takes a few seconds --
and a running count of files, folders and both size totals shows while it
works.  **Cancel** stops it.

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
| **Hover** | Full path and size in the status bar |
| **Cmd-Up** | Up one level |
| **Shift-Cmd-Up** | Back to the top |
| **Shift-Cmd-G** | Jump to a folder by name |
| **Cmd-R** | Scan the same folder again |

The path in the toolbar runs from the folder you scanned down to where you are
now -- `claude/src/Plat` rather than just `claude`, so the outermost folder is
always named.  **Click any element of it to jump there.**  It sits in the
toolbar rather than in a bar of its own because a window title cannot be
clicked, and a separate strip would cost a row of screen space for something
the title bar already has room for.  The window title itself is left empty
while a scan is showing, since the path already names the folder.  A path deeper than five levels folds its
leading elements into a menu.

**Plat > About Plat** reports the version, the commit it was built from, and
-- if it was built from a tree with uncommitted edits -- says so, in orange,
with the time it was built.  A build from a modified tree corresponds to no
commit, so the hash alone would be misleading.

The details panel is set large enough to read at a glance.  It gives the size
both readably and in exact bytes, the kind of file, how many items a folder
holds directly and in total, and what share of its parent and of the whole scan
it accounts for.  **Click the name or the path in the panel to copy it.**
There are buttons to **Quick Look** it, **Open** it in whatever application
handles it, **Reveal** it in the Finder, and to zoom in.  Quick Look is the
same system panel the Finder uses -- it is not Finder-only, any app can drive
it -- so a picture or a movie previews in place without launching anything.  A
scan is a snapshot, so if the file has been deleted since, the panel says so
and those buttons are disabled.

## Reading the map

* **Coloured boxes are files.**  The colour comes from the file extension, so
  all the videos in a folder, or all the object files, read as one block.
* **Pale boxes with a title strip are folders** that have been opened up to
  show what is inside them.
* **Solid blue-grey boxes are folders that were not opened** -- either the box
  was too small to subdivide usefully, or you limited the depth.  There is more
  inside them than the map is showing.
* **A red triangle in a corner marks a hard link.**  See below; it matters.
* **A grey box reading "N smaller items"** stands in for a tail of files too
  small to draw individually.  Their space is still counted.

The **Aa** toggle in the toolbar turns the labels off, which gives the boxes
themselves more room.

## Applications and other bundles

An application is one thing to install, one thing to delete and one thing to
reason about, so Plat draws it as one box.  `Thing.app` shows up with its whole
weight and a flat colour, exactly like a file -- no label strip, nothing inside
it to click.  The same goes for a Photos library, a Pages document, a sparse
bundle and the rest of the directories macOS presents as single objects.

This is not a cosmetic choice.  Deleting one file out of a bundle breaks it, so a
map that invites you to poke around inside one is inviting a mistake; the map and
the delete rules read the same table of bundle types, so they cannot disagree.

**Double-click** a bundle to look inside it anyway.  Zooming in makes it the root
of the map, and the root is always opened -- so exploring one costs a double
click and nothing else.  To open them all up at once, turn off **Treat Bundles as
Single Files** (**Shift-Cmd-B**) in the View menu.

The difference is large on a real disk.  A scan of `/Applications` here draws
2,402 boxes with bundles open and 498 with them shut, and the shut version is the
one that answers "which application is eating the disk?".

## Colours and fonts

**Plat > Settings** (Cmd-,) has two tabs.

*Colors* gives a well for each part of the map -- background, open folder,
unopened folder, the grouped-small-files block, the hard-link flag, box
outline, label text and hover highlight -- each labelled with what it actually
colours.

Below those, **file kinds**.  Every file takes the colour of its kind --
Application, Archive, Document, Executable, Image, Movie, Music, PDF,
Presentation, Text or Other -- and each has a well.  The kind is not a table of
extensions kept in this project: macOS already knows, through Uniform Type
Identifiers, so anything the system recognises is classified without being
listed here.  Each row also shows a few extensions from the scan you have open
that land in that kind, so "Document" is not left to the imagination.

Two decisions this project makes on top of Apple's hierarchy, since several
types conform to more than one supertype:

* An interpreted program is the file you run, so `.py`, `.js`, `.sh` and the
  rest are **Executable**, alongside `.o` and `.dylib`.  Source that has to be
  compiled -- `.swift`, `.m`, `.c` -- conforms to neither and stays **Text**,
  which is right: there the binary is the program, not the source.
* PDF is checked before Document, and Application before Archive, because a PDF
  is composite content too and an app is a bundle.

Finally, **pinned extensions** override the kind.  Pin `.swift` orange and
`.m` blue whatever their kinds say; type an extension with or without the
leading dot, in any case.  This is also the escape hatch when the system's
guess is wrong for your work.

One such case is corrected already: `.ts` resolves to an MPEG-2 transport
stream and `.mts` to AVCHD video, so a source tree would report hundreds of
megabytes of "Movie".  The TypeScript family (`.ts`, `.tsx`, `.mts`, `.cts`) is
classified as Text, which is where compiled-from source belongs.  It follows
the Text colour, so recolouring Text moves it too -- and pinning `.ts`
directly still overrides that.  The dialog lists the extensions using the most space in the open
scan, each in the colour it currently has; clicking one pins it at that colour,
so nothing moves until you change it.

*Fonts* sets the family and size of the labels drawn inside boxes, and the size
of the details panel.  Raising the map font raises the label strip with it, so
labels are never clipped -- but a taller strip means fewer boxes are large
enough to subdivide, so the map gets coarser.  The panel's name and smaller
text scale from the one figure size.

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

"Not scanned" is deliberately one block.  macOS reports no size per snapshot --
snapshot blocks are shared with live files, so there is no single number to
report -- and splitting it further would mean inventing figures.  A large one
usually means either many local snapshots (`tmutil listlocalsnapshots /`) or a
scan that could not read much of the disk.

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

Finding the space is only half of it.  Select a box and press **Delete**, or use
**Move to Trash** in the details popover.

Nothing is ever unlinked.  Items go to the Trash, and **Cmd-Z** puts the last one
back -- on disk and on the map.  The map updates immediately: the folder's boxes
disappear, every folder above it shrinks, and on a whole-volume scan the freed
blocks show up in the free-space block, so the picture still adds up to the size
of the disk without a rescan.

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

Some of the reasoning is worth knowing about:

* **Inside a package.**  Deleting one file out of `Thing.app` invalidates its
  code signature, and macOS will then usually refuse to launch it -- with an
  error that never mentions the missing file.  The same goes for a
  `.photoslibrary` or a `.pages` document, which look like single files in the
  Finder but are really folders.  This test runs before every other rule,
  because an Electron application ships its own `node_modules` and calling that
  one safe would break the app.
* **Running right now.**  If the item belongs to an application that is running,
  the verdict is raised and says so by name.
* **Hard links.**  Plat already knows how many names point at a file, so it can
  tell you a delete will recover *nothing* before you make it.
* **Permissions.**  Removing an item needs write permission on the folder that
  contains it, not on the item -- which is the usual mistake, and the reason a
  delete fails with no explanation.
* **iCloud.**  Anything under `~/Library/Mobile Documents` is removed from every
  device signed in to the same account, and this Mac's Trash will not bring it
  back on the others.  Files whose contents have been evicted to iCloud free no
  space here at all.

### Answering it

**Y** deletes.  Any other key closes the box.

Nothing is bound to Return, on purpose: the box is often the thing standing
between a stray keystroke and a folder, and a dialog where the reflex answer is
also the destructive one is not much of a dialog.  Y is a letter nobody presses
by accident, and every other key -- Return, Escape, space, a wrong guess -- is a
cancel.  The buttons work too, for a hand already on the mouse.

The box stays short when the delete is ordinary: the name, what it recovers, and
the instruction.  Reasons only appear when there is something to be careful
about, because a confirmation that always prints five paragraphs teaches people
to dismiss it unread.

Plat asks before every delete.  Turning that off in **Settings > General** skips
the question for ordinary files only; anything risky still asks.

## Tooltips

Hover over a box and its name appears after the usual delay.  Just the name --
the status bar along the bottom already carries the full path and the size, and
a tooltip that repeats them covers the map with something you have to read
twice.  For a box too small to fit its label, which is most of them on a full
disk, this is the only thing that says what it is.

While the tooltip is up it follows the pointer, and it changes the moment the
pointer crosses into another box, with no second wait.

## Looking at a file

Press **Space** over a box to Quick Look it -- the same preview the
Finder gives, in the same system panel.  A capacity block has no file to
preview, and neither does a name whose file has since been deleted; those show
the details popover instead.

The details popover reports what the file actually contains, from `file(1)`:

    Kind      PNG image
    Contents  PNG image data, 1024 x 1024, 8-bit/color RGBA, non-interlaced

An extension is a claim and magic numbers are evidence, so the two disagree when
a file has the wrong name -- **Kind** comes from the extension, **Contents** from
the first bytes on disk.

## Dragging things out

Drag a box out of Plat and it behaves like a file, because it is one.  Drop it on
a Finder window, into a mail message, onto a terminal, anywhere that takes a
file.  The drag carries a real file URL and the file's own icon.

* **Dropping on the Finder** copies or moves it, following the usual rules and
  the usual modifier keys.
* **Dropping on the Trash** deletes it, and Plat notices.
* **Anything Plat can call risky** -- a file inside an application bundle, a
  startup item, iCloud Drive -- is offered for **copying only**.  A drag has
  nowhere to put a warning, so the protection has to be in what is offered; the
  Finder shows a copy badge rather than a move one.  Deleting has a confirmation
  it can stop you at, and dragging does not.

Plat cannot tell in advance what a drop will do, and neither can any other
application: `NSDraggingSource` is handed a screen point as the drag moves and
nothing else, and `NSDraggingSession` has no property for the operation the
system is currently negotiating.  Even afterwards, the operation reported back
is what the destination *said* it would do, not what it did -- an image editor
that opens a file and touches nothing still has to answer something, and
`NSDragOperationGeneric` means nothing at all about the filesystem.

So Plat looks at the disk instead, then re-reads the volume's own figures.  The
reported operation is used for one thing only: deciding how long to keep
looking.  A drop that claims to be taking the file away is watched for a few
seconds, because dragging a large folder to another volume is a copy followed by
a delete and it can still be running after the mouse comes up.  A file
moved to another folder on the same volume frees nothing at all, and Plat is
never told where it went -- so the map shows the folder shrinking while free
space stays exactly where it was, and the difference lands in **Not scanned**,
which is what that block has always meant.

Dropping a box on another box, to move a file inside the map, is not supported.
The tree stores children as contiguous runs, so accepting one somewhere new
means rebuilding it, and a move that cannot be undone is not worth that yet.

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
* **Firmlink duplicates** are counted once.  macOS presents the System and Data
  volumes of a volume group as one filesystem sharing a single device id, and
  connects them with firmlinks, so `/Users` and `/System/Volumes/Data/Users`
  are the same directory reached two ways.  A scan of `/` would meet the whole
  Data volume twice; Plat keeps the familiar path and drops the duplicate,
  using the system's own table at `/usr/share/firmlinks`.  `/System/Volumes/Data`
  itself is still scanned, because plenty there -- `.Spotlight-V100`,
  `.DocumentRevisions-V100`, `MobileSoftwareUpdate` -- has no firmlink pointing
  at it.
* **Sockets, pipes and devices** are skipped; they occupy no meaningful space.
* **Folders themselves** are measured only by what they contain.  The few
  blocks a directory's own entries occupy are not counted, so a total can sit a
  hair under `du`.
* **APFS clones** -- files duplicated with copy-on-write -- are counted in
  full, once each, because each one honestly reports owning its blocks.  `du`
  does the same.  Only the filesystem knows they are shared.

Hidden files and folders *are* included, at every level: `.git`, `.build`,
`.local` and the rest all show up.

## Building from source

Needs a Swift 6 toolchain; built and tested with Xcode 26.

    make            # build build/Plat.app
    make test       # 118 tests
    make install    # also install into ~/Applications
    make release    # build build/Plat-<version>-macos-<arch>.dmg
    make tag        # annotated tag v<version> for the current commit
    make push-tag   # push that tag to origin

The `Version` file gives the release version; the commit hash, its date, and
whether the tree was dirty are read from git at build time by
`scripts/version-info.sh` and stamped into the app's `Info.plist`, where the
About box reads them.  Only tracked edits count as dirty, so stray untracked
files do not mark a build modified.  Nothing is generated into a source file,
so building never leaves a modified file behind in git.

`make install` takes `DESTDIR=/Applications` to install for all users.  The
build also makes the icon: `icons/AppIcon.png` is the 1024x1024 master,
resampled to the ten sizes macOS wants and packed into `AppIcon.icns`.  The
`Version` file is the single source of truth for the bundle version and the
disk image name.

A local build is ad-hoc signed -- fine on the machine that built it, but a copy
downloaded from anywhere else stays quarantined.  For a release that opens with
no warnings, pass a Developer ID; the app is then signed with the hardened
runtime and a secure timestamp, and the image is notarized and stapled:

    make release \
      CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
      NOTARY_PROFILE=plat-notary

Cutting a release: bump `Version`, commit, `make release` with a Developer ID,
then `make tag` and `make push-tag`.  `make tag` refuses a dirty tree, because a
build from uncommitted edits stamps itself "modified" and names a commit that
does not describe it -- and refuses a version already tagged, so the `Version`
file has to be bumped first.

`NOTARY_PROFILE` names a profile stored with `xcrun notarytool
store-credentials`.  Plat links only system frameworks and needs no
entitlements, so there is no nested code to sign and nothing to grant.

    Sources/PlatCore/    scanner, tree, treemap, renderer -- no AppKit
    Sources/PlatApp/     SwiftUI window, NSView host, model
    Sources/PlatBench/   benchmark and offscreen PNG renderer
    Tests/PlatCoreTests/ 118 tests

`plat-bench` scans a tree and reports timings, and can render a treemap
straight to a PNG without opening a window:

    plat-bench ~/src --render out.png --layout classic --size 1600x1000

## How it works

The scan uses `getattrlistbulk(2)`, which returns the name, type, device and
sizes of many directory entries in a single system call, and runs several
directories at once on a small pool of threads, because filesystem metadata
reads are latency-bound.  A tree of 1.3 million files scans in about three
seconds.

The tree is held as two flat buffers -- one array of fixed-size nodes and one
blob of name bytes -- rather than a graph of small allocations, and paths are
rebuilt on demand by walking to the root rather than stored.  That is what
keeps a multi-million-file scan inside a few hundred megabytes.

The layout is computed once per view and reused for drawing, hit testing and
hover, and it only descends into boxes large enough to see.  Laying out a
750,000-node tree takes about a millisecond, so resizing and navigating stay
immediate no matter how large the scan.
