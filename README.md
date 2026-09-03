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
There are buttons to zoom in and to reveal the item in the Finder.

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
guess is wrong for your work -- `.ts` resolves to an MPEG transport stream, not
TypeScript.  The dialog lists the extensions using the most space in the open
scan, each in the colour it currently has; clicking one pins it at that colour,
so nothing moves until you change it.

*Fonts* sets the family and size of the labels drawn inside boxes, and the size
of the details panel.  Raising the map font raises the label strip with it, so
labels are never clipped -- but a taller strip means fewer boxes are large
enough to subdivide, so the map gets coarser.  The panel's name and smaller
text scale from the one figure size.

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
    make test       # 66 tests
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
    Tests/PlatCoreTests/ 66 tests

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
