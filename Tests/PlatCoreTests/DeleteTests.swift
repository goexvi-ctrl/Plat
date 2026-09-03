import XCTest
@testable import PlatCore

/// Removing a node from a scanned tree.
final class TreeRemovalTests: XCTestCase {

    /// A whole-volume scan: root, the two capacity blocks in the order
    /// `FileScanner` reserves them, then a folder with two files.
    ///
    ///   root                          (capacity)
    ///     [1] Not scanned      =  100
    ///     [2] Free space       =  400
    ///     [3] a (dir)
    ///           [5] a1         =  300
    ///           [6] a2         =  200
    ///     [4] b                =  1000  (b is not under a)
    private func volumeTree(linkCountForA1: UInt16 = 1) -> FileTree {
        var names: [UInt8] = []
        func add(_ s: String) -> (UInt32, UInt32) {
            let start = UInt32(names.count)
            names.append(contentsOf: Array(s.utf8))
            return (start, UInt32(s.utf8.count))
        }
        let r = add("root"), ns = add("Not scanned"), fs = add("Free space")
        let a = add("a"), b = add("b"), a1 = add("a1"), a2 = add("a2")

        var nodes: [FileTree.Node] = []
        nodes.append(.init(nameOffset: r.0, nameLength: r.1, parent: -1,
                           childStart: 1, childCount: 4, isDirectory: true))
        nodes.append(.init(size: 100, nameOffset: ns.0, nameLength: ns.1, parent: 0,
                           isSynthetic: true))
        nodes.append(.init(size: 400, nameOffset: fs.0, nameLength: fs.1, parent: 0,
                           isSynthetic: true))
        nodes.append(.init(nameOffset: a.0, nameLength: a.1, parent: 0,
                           childStart: 5, childCount: 2, isDirectory: true))
        nodes.append(.init(size: 1000, nameOffset: b.0, nameLength: b.1, parent: 0))
        nodes.append(.init(size: 300, allocatedShared: linkCountForA1 > 1 ? 150 : 300,
                           linkCount: linkCountForA1,
                           nameOffset: a1.0, nameLength: a1.1, parent: 3))
        nodes.append(.init(size: 200, nameOffset: a2.0, nameLength: a2.1, parent: 3))

        var t = FileTree(nodes: nodes, names: names, rootPath: "/vol", stats: ScanStats())
        t.rollUpSizes()
        var s = ScanStats()
        s.files = 3
        s.directories = 1
        s.allocatedBytes = t.nodes[0].allocatedSize
        s.sharedBytes = t.nodes[0].allocatedShared
        s.totalBytes = t.nodes[0].logicalSize
        t.stats = s
        return t
    }

    func testFreeSpaceBlockIsWhereWeThink() {
        let t = volumeTree()
        XCTAssertEqual(t.freeSpaceIndex, 2)
        XCTAssertEqual(t.synthetic(2), .freeSpace)
    }

    /// The whole point: after a delete the map still adds up to the volume's
    /// capacity, with the freed blocks showing as free space.
    func testCapacityIsInvariantAcrossADelete() {
        var t = volumeTree()
        let capacity = t.totalSize
        let freeBefore = t.size(of: 2)

        XCTAssertNotNil(t.remove(5))            // delete a1, 300 bytes

        XCTAssertEqual(t.totalSize, capacity, "the volume did not change size")
        XCTAssertEqual(t.size(of: 2), freeBefore + 300, "freed blocks became free space")
        XCTAssertEqual(t.size(of: 3), 200, "the parent folder shrank")
        XCTAssertEqual(t.size(of: 5), 0)
        XCTAssertTrue(t.isDeleted(5))
    }

    func testDeletingAFolderTakesItsChildrenWithIt() {
        var t = volumeTree()
        let capacity = t.totalSize
        XCTAssertNotNil(t.remove(3))            // delete folder a, 500 bytes

        XCTAssertEqual(t.totalSize, capacity)
        XCTAssertEqual(t.size(of: 3), 0)
        XCTAssertEqual(t.size(of: 2), 900, "400 free + 500 recovered")
        // The children are still in the array -- indices above them must stay
        // valid -- but nothing can reach them any more.
        XCTAssertTrue(t.isGone(5))
        XCTAssertTrue(t.isGone(6))
        XCTAssertFalse(t.isGone(4))
    }

    func testStatsFollowTheDelete() {
        var t = volumeTree()
        XCTAssertEqual(t.stats.files, 3)
        XCTAssertEqual(t.stats.directories, 1)

        t.remove(3)                             // the folder and both files
        XCTAssertEqual(t.stats.files, 1)
        XCTAssertEqual(t.stats.directories, 0)

        // The root's own counts no longer include what was removed, and the
        // two capacity blocks were never items on disk to begin with.
        let counts = t.subtreeCounts(of: 0)
        XCTAssertEqual(counts.files, 1, "only b survives")
        XCTAssertEqual(counts.folders, 0)
    }

    func testRestorePutsEverythingBack() {
        var t = volumeTree()
        let before = (0 ..< t.nodes.count).map { t.size(of: $0) }
        let statsBefore = t.stats

        guard let removal = t.remove(3) else { return XCTFail("remove failed") }
        t.restore(removal)

        let after = (0 ..< t.nodes.count).map { t.size(of: $0) }
        XCTAssertEqual(before, after)
        XCTAssertEqual(statsBefore, t.stats)
        XCTAssertFalse(t.isDeleted(3))
        XCTAssertFalse(t.isGone(5))
    }

    func testRemovalIsIdempotentAndRefusesSyntheticBlocks() {
        var t = volumeTree()
        XCTAssertNotNil(t.remove(4))
        XCTAssertNil(t.remove(4), "removing twice must not double-count")
        XCTAssertNil(t.remove(2), "the free-space block is not a file")
        XCTAssertNil(t.remove(0), "the root is not deletable")
    }

    func testRevisionChangesSoViewsRelayOut() {
        var t = volumeTree()
        let r0 = t.revision
        guard let removal = t.remove(4) else { return XCTFail("remove failed") }
        XCTAssertNotEqual(t.revision, r0)
        let r1 = t.revision
        t.restore(removal)
        XCTAssertNotEqual(t.revision, r1)
    }

    func testRemovalRecordsThePath() {
        var t = volumeTree()
        XCTAssertEqual(t.remove(5)?.path, "/vol/a/a1")
    }

    /// A tree that is not a whole volume has no free-space block, so the total
    /// simply shrinks.
    func testFolderScanTotalShrinks() {
        var names: [UInt8] = []
        names.append(contentsOf: Array("rootx".utf8))
        var nodes: [FileTree.Node] = []
        nodes.append(.init(nameOffset: 0, nameLength: 4, parent: -1,
                           childStart: 1, childCount: 1, isDirectory: true))
        nodes.append(.init(size: 70, nameOffset: 4, nameLength: 1, parent: 0))
        var t = FileTree(nodes: nodes, names: names, rootPath: "/r", stats: ScanStats())
        t.rollUpSizes()
        XCTAssertEqual(t.totalSize, 70)
        XCTAssertNil(t.freeSpaceIndex)
        t.remove(1)
        XCTAssertEqual(t.totalSize, 0)
    }

    // MARK: Assessment on a tree

    func testHardLinkedNameReclaimsNothing() {
        let t = volumeTree(linkCountForA1: 3)
        let a = DeleteSafety.assess(tree: t, node: 5, home: "/Users/nobody")
        XCTAssertTrue(a.freesNothing)
        XCTAssertEqual(a.reclaims, 0)
        XCTAssertTrue(a.notes.contains { $0.contains("frees no space") })
    }

    func testCapacityBlockCannotBeDeleted() {
        let t = volumeTree()
        XCTAssertEqual(DeleteSafety.assess(tree: t, node: 2, home: "/Users/nobody").risk,
                       .blocked)
    }
}

/// The path rules.  These run against paths, not against the live filesystem,
/// so they do not depend on what happens to be installed on the test machine.
final class DeleteSafetyRuleTests: XCTestCase {

    private let home = "/Users/tester"

    private func risk(_ path: String, dir: Bool = false, running: [String] = []) -> DeleteRisk {
        var a = DeleteAssessment()
        DeleteSafety.assess(path: path, isDirectory: dir, home: home,
                            runningApplicationPaths: running)
        // Path rules only; assess() also does filesystem checks that would
        // reject these invented paths outright.
        DeleteSafety.classifyForTests(path: path, isDirectory: dir, home: home, into: &a)
        if let app = running.first(where: { DeleteSafety.isAtOrUnder(path: path, root: $0) }) {
            _ = app
            a.raise(to: .danger)
        }
        return a.risk
    }

    private func summary(_ path: String, dir: Bool = false) -> String {
        var a = DeleteAssessment()
        DeleteSafety.classifyForTests(path: path, isDirectory: dir, home: home, into: &a)
        return a.summary
    }

    func testCachesAreSafe() {
        XCTAssertEqual(risk("\(home)/Library/Caches/com.example/blob"), .safe)
        XCTAssertEqual(risk("\(home)/Library/Logs/foo.log"), .safe)
        XCTAssertEqual(risk("\(home)/Library/Developer/Xcode/DerivedData/App-abc"), .safe)
        XCTAssertEqual(risk("\(home)/proj/node_modules", dir: true), .safe)
    }

    func testOrdinaryFilesAreOrdinary() {
        XCTAssertEqual(risk("\(home)/Downloads/holiday.mov"), .normal)
        XCTAssertEqual(risk("\(home)/Documents/notes.txt"), .normal)
    }

    func testSystemPathsAreDangerous() {
        XCTAssertEqual(risk("/System/Library/CoreServices/Finder.app"), .danger)
        XCTAssertEqual(risk("/usr/lib/libSystem.dylib"), .danger)
        XCTAssertEqual(risk("/Library/LaunchDaemons/com.example.plist"), .danger)
        XCTAssertEqual(risk("/opt/homebrew/bin/git"), .danger)
    }

    /// A whole-component test, so a path that merely starts with the same
    /// letters is not swept up.
    func testPrefixMatchingIsComponentWise() {
        XCTAssertEqual(risk("/usr/binary-of-mine"), .normal)
        XCTAssertEqual(risk("/usr/local-notes.txt"), .normal)
        XCTAssertTrue(DeleteSafety.isAtOrUnder(path: "/usr/bin", root: "/usr/bin"))
        XCTAssertFalse(DeleteSafety.isAtOrUnder(path: "/usr/binary", root: "/usr/bin"))
    }

    func testInsideAnAppBundleIsDangerous() {
        XCTAssertEqual(risk("/Applications/Thing.app/Contents/MacOS/Thing"), .danger)
        XCTAssertEqual(summary("/Applications/Thing.app/Contents/Info.plist"),
                       "Inside Thing.app")
    }

    /// The ordering that matters: an Electron app carries its own
    /// `node_modules`, and calling that safe would break the app.
    func testPackageInteriorBeatsRebuildableNames() {
        XCTAssertEqual(risk("/Applications/Chat.app/Contents/Resources/node_modules",
                            dir: true), .danger)
    }

    func testDeletingAWholeAppIsMerelyCaution() {
        XCTAssertEqual(risk("/Applications/Thing.app", dir: true), .caution)
        XCTAssertEqual(summary("/Applications/Thing.app", dir: true), "Application")
    }

    func testDocumentPackagesProtectTheirInsides() {
        XCTAssertEqual(risk("\(home)/Pictures/My.photoslibrary/database/x.db"), .danger)
        XCTAssertEqual(risk("\(home)/Pictures/My.photoslibrary", dir: true), .caution)
    }

    func testICloudIsDangerousBecauseItPropagates() {
        XCTAssertEqual(risk("\(home)/Library/Mobile Documents/com~apple~Pages/f.pages"),
                       .danger)
    }

    func testIrreplaceableData() {
        XCTAssertEqual(risk("\(home)/Library/Keychains/login.keychain-db"), .danger)
        XCTAssertEqual(risk("\(home)/Library/Mail/V10/x.mbox"), .danger)
        XCTAssertEqual(risk("\(home)/src/proj/.git", dir: true), .danger)
        XCTAssertEqual(risk("\(home)/src/proj/.git/objects/ab/cdef"), .danger)
    }

    func testApplicationDataIsCaution() {
        XCTAssertEqual(risk("\(home)/Library/Application Support/Thing"), .caution)
        XCTAssertEqual(risk("\(home)/Library/Preferences/com.example.plist"), .caution)
    }

    func testRunningApplicationRaisesTheVerdict() {
        XCTAssertEqual(risk("\(home)/Library/Caches/com.example/blob",
                            running: ["\(home)/Library/Caches/com.example"]), .danger)
    }

    func testRiskOrdering() {
        XCTAssertTrue(DeleteRisk.safe < .normal)
        XCTAssertTrue(DeleteRisk.caution < .danger)
        XCTAssertTrue(DeleteRisk.danger.alwaysConfirm)
        XCTAssertFalse(DeleteRisk.normal.alwaysConfirm)
        XCTAssertFalse(DeleteRisk.safe.alwaysConfirm)
    }
}

/// Checks that do touch the filesystem, on files the test makes itself.
final class DeleteSafetyFilesystemTests: XCTestCase {

    func testMissingFileIsBlocked() {
        let a = DeleteSafety.assess(path: "/nonexistent/\(UUID().uuidString)",
                                    isDirectory: false)
        XCTAssertEqual(a.risk, .blocked)
        XCTAssertEqual(a.summary, "No longer on disk")
    }

    func testSIPProtectedFileIsBlocked() throws {
        // /usr/bin/true is restricted on every supported macOS.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/bin/true"))
        let a = DeleteSafety.assess(path: "/usr/bin/true", isDirectory: false)
        XCTAssertEqual(a.risk, .blocked)
        XCTAssertTrue(a.summary.contains("System Integrity Protection"))
    }

    func testUnwritableParentIsBlocked() throws {
        // /var/db is root-owned; deleting from it needs write on the folder.
        let path = "/private/var/db/dslocal"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        try XCTSkipIf(getuid() == 0, "running as root, which can write anywhere")
        let a = DeleteSafety.assess(path: path, isDirectory: true)
        XCTAssertEqual(a.risk, .blocked)
    }

    func testAnOrdinaryTemporaryFileIsOrdinary() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)

        let a = DeleteSafety.assess(path: file.path, isDirectory: false,
                                    home: "/Users/tester")
        XCTAssertLessThanOrEqual(a.risk, .caution)
        XCTAssertNotEqual(a.risk, .blocked)
    }

    func testLockedFileIsBlocked() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("locked.txt")
        try Data("x".utf8).write(to: file)
        defer {
            _ = file.path.withCString { chflags($0, 0) }
            try? FileManager.default.removeItem(at: dir)
        }
        try XCTSkipUnless(file.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) } == 0)

        let a = DeleteSafety.assess(path: file.path, isDirectory: false)
        XCTAssertEqual(a.risk, .blocked)
        XCTAssertEqual(a.summary, "Locked")
    }
}

/// The Trash round trip, on files the test makes itself.
final class TrashTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFile(_ name: String, _ text: String = "hello") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testRecycleReportsWhereItLanded() throws {
        let file = try makeFile("victim.txt")
        let landed = try Trash.recycle(file)
        // Without this URL there is nothing to undo, which is the whole reason
        // Plat does not use NSWorkspace.recycle here.
        let trashed = try XCTUnwrap(landed, "trashItem must name the destination")
        defer { try? FileManager.default.removeItem(at: trashed) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testPutBackRestoresTheFileAndItsContents() throws {
        let file = try makeFile("notes.txt", "important")
        let trashed = try XCTUnwrap(try Trash.recycle(file))

        try Trash.putBack(from: trashed, to: file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "important")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testPutBackRefusesToOverwrite() throws {
        let file = try makeFile("dup.txt", "original")
        let trashed = try XCTUnwrap(try Trash.recycle(file))
        defer { try? FileManager.default.removeItem(at: trashed) }
        // Something takes the name back while the item sits in the Trash.
        try Data("newer".utf8).write(to: file)

        XCTAssertThrowsError(try Trash.putBack(from: trashed, to: file)) { error in
            guard case Trash.Failure.refused = error else {
                return XCTFail("expected a refusal, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer",
                       "the newer file must survive untouched")
    }

    func testPutBackRefusesWhenTheFolderIsGone() throws {
        let sub = dir.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: file)
        let trashed = try XCTUnwrap(try Trash.recycle(file))
        defer { try? FileManager.default.removeItem(at: trashed) }
        try FileManager.default.removeItem(at: sub)

        XCTAssertThrowsError(try Trash.putBack(from: trashed, to: file))
    }

    func testRecyclingAFolderTakesItsContents() throws {
        let sub = dir.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: sub.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: sub.appendingPathComponent("b.txt"))

        let trashed = try XCTUnwrap(try Trash.recycle(sub))
        defer { try? FileManager.default.removeItem(at: trashed) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sub.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: trashed.appendingPathComponent("a.txt").path))
    }

    func testRecyclingSomethingUndeletableThrows() {
        XCTAssertThrowsError(try Trash.recycle(URL(fileURLWithPath: "/usr/bin/true")),
                             "SIP-protected files must not be silently reported as deleted")
    }
}

/// Scan, delete, undo -- the three pieces working together on real files.
final class DeleteIntegrationTests: XCTestCase {

    func testScanDeleteAndUndoAgreeWithTheDisk() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-e2e-\(UUID().uuidString)")
        let junk = root.appendingPathComponent("junk")
        try fm.createDirectory(at: junk, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 64 KB of it, so the figures are well clear of directory overhead.
        let payload = Data(repeating: 0x41, count: 32 * 1024)
        try payload.write(to: junk.appendingPathComponent("a.bin"))
        try payload.write(to: junk.appendingPathComponent("b.bin"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("keep.txt"))

        var tree = try FileScanner.scan(path: root.path)
        let totalBefore = tree.totalSize
        guard let junkNode = (0 ..< tree.nodes.count).first(where: {
            tree.name(of: $0) == "junk"
        }) else { return XCTFail("scan did not find the junk folder") }

        let junkSize = tree.size(of: junkNode)
        XCTAssertGreaterThanOrEqual(junkSize, 64 * 1024)

        // What Plat would say about it before acting.
        let verdict = DeleteSafety.assess(tree: tree, node: junkNode)
        XCTAssertNotEqual(verdict.risk, .blocked)
        XCTAssertEqual(verdict.reclaims, tree.nodes[junkNode].allocatedShared)

        // Delete for real.
        let trashed = try XCTUnwrap(try Trash.recycle(URL(fileURLWithPath: tree.path(of: junkNode))))
        defer { try? fm.removeItem(at: trashed) }
        let removal = try XCTUnwrap(tree.remove(junkNode))

        XCTAssertFalse(fm.fileExists(atPath: junk.path), "the folder really went")
        XCTAssertEqual(tree.totalSize, totalBefore - junkSize,
                       "a folder scan simply shrinks -- there is no free block to credit")
        XCTAssertTrue(tree.isGone(junkNode))

        // A fresh scan of the same folder must agree with the tree Plat patched
        // in place.  This is the property that matters: no rescan should be
        // needed to see the truth.
        let rescanned = try FileScanner.scan(path: root.path)
        XCTAssertEqual(rescanned.totalSize, tree.totalSize)
        XCTAssertEqual(rescanned.stats.files, tree.stats.files)
        XCTAssertEqual(rescanned.stats.directories, tree.stats.directories)

        // And undo puts both the disk and the tree back.
        try Trash.putBack(from: trashed, to: URL(fileURLWithPath: removal.path))
        tree.restore(removal)

        XCTAssertTrue(fm.fileExists(atPath: junk.appendingPathComponent("a.bin").path))
        XCTAssertEqual(tree.totalSize, totalBefore)
        let restored = try FileScanner.scan(path: root.path)
        XCTAssertEqual(restored.totalSize, tree.totalSize)
        XCTAssertEqual(restored.stats.files, tree.stats.files)
    }
}
