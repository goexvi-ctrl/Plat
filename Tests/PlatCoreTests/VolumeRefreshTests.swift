import XCTest
@testable import PlatCore

/// Re-reading the volume's real figures after Plat changes something on disk.
///
/// Uses its own 32 MB disk image, for the same reason `VolumeCapacityTests`
/// does: a real mount point whose contents the test controls, and seconds
/// rather than a walk of the whole machine.
final class VolumeRefreshTests: XCTestCase {

    nonisolated(unsafe) private static var image: URL!
    nonisolated(unsafe) private static var mount: String!

    override class func setUp() {
        super.setUp()
        let dmg = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-refresh-\(UUID().uuidString).dmg")
        guard run("/usr/bin/hdiutil",
                  ["create", "-quiet", "-size", "32m", "-fs", "APFS",
                   "-volname", "PlatRefreshTest", "-ov", dmg.path]) != nil,
              let attach = run("/usr/bin/hdiutil", ["attach", "-nobrowse", dmg.path])
        else { return }
        image = dmg
        for line in attach.split(separator: "\n") {
            let text = String(line)
            guard let r = text.range(of: "/Volumes/") else { continue }
            mount = String(text[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }
    }

    override class func tearDown() {
        if let mount { _ = run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]) }
        if let image { try? FileManager.default.removeItem(at: image) }
        super.tearDown()
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    private func mountPoint() throws -> String {
        try XCTUnwrap(Self.mount, "could not mount the test volume")
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = URL(fileURLWithPath: try mountPoint()).appendingPathComponent(name)
        try Data(repeating: 9, count: bytes).write(to: url)
        return url
    }

    private func clean() throws {
        let m = try mountPoint()
        for entry in try FileManager.default.contentsOfDirectory(atPath: m)
        where entry != ".fseventsd" {
            try? FileManager.default.removeItem(atPath: m + "/" + entry)
        }
    }

    override func setUpWithError() throws { try clean() }
    override func tearDownWithError() throws { try? clean() }

    /// Refreshing with nothing changed must leave the picture exactly as it was.
    func testRefreshIsIdempotent() throws {
        _ = try write("blob.bin", bytes: 4_000_000)
        var tree = try FileScanner.scan(path: try mountPoint())
        XCTAssertNotNil(tree.freeSpaceIndex)

        let before = (0 ..< tree.nodes.count).map { tree.size(of: $0) }
        XCTAssertTrue(tree.refreshVolumeAccounting())
        XCTAssertEqual((0 ..< tree.nodes.count).map { tree.size(of: $0) }, before)
    }

    /// The property the whole capacity model rests on: the root equals the
    /// volume, before and after.
    func testRootStillEqualsCapacityAfterARemoval() throws {
        let victim = try write("victim.bin", bytes: 4_000_000)
        _ = try write("keep.bin", bytes: 1_000_000)
        var tree = try FileScanner.scan(path: try mountPoint())
        let capacity = try XCTUnwrap(tree.volume).totalBytes
        XCTAssertEqual(tree.totalSize, capacity)

        let node = try XCTUnwrap((0 ..< tree.nodes.count)
            .first { tree.name(of: $0) == "victim.bin" })
        try FileManager.default.removeItem(at: victim)
        tree.remove(node)
        XCTAssertTrue(tree.refreshVolumeAccounting())

        XCTAssertEqual(tree.totalSize, capacity, "the volume is still the volume")
        XCTAssertEqual(tree.volume?.totalBytes, capacity)
    }

    /// Free space is read from the filesystem, not inferred, so a real deletion
    /// shows up as real free space.
    func testFreedSpaceComesFromTheFilesystem() throws {
        let victim = try write("victim.bin", bytes: 8_000_000)
        var tree = try FileScanner.scan(path: try mountPoint())
        let freeBefore = tree.size(of: try XCTUnwrap(tree.freeSpaceIndex))

        let node = try XCTUnwrap((0 ..< tree.nodes.count)
            .first { tree.name(of: $0) == "victim.bin" })
        try FileManager.default.removeItem(at: victim)
        tree.remove(node)
        tree.refreshVolumeAccounting()

        let freeAfter = tree.size(of: try XCTUnwrap(tree.freeSpaceIndex))
        XCTAssertGreaterThan(freeAfter, freeBefore + 6_000_000,
                             "roughly 8 MB came back, measured not guessed")
    }

    /// A move within the volume frees nothing.  `remove` alone would credit the
    /// free block anyway; the refresh is what stops Plat inventing space that
    /// was never returned.
    func testMovingWithinTheVolumeFreesNothing() throws {
        let file = try write("wanderer.bin", bytes: 6_000_000)
        let elsewhere = URL(fileURLWithPath: try mountPoint())
            .appendingPathComponent("moved.bin")
        var tree = try FileScanner.scan(path: try mountPoint())
        let freeIdx = try XCTUnwrap(tree.freeSpaceIndex)
        let freeBefore = tree.size(of: freeIdx)

        let node = try XCTUnwrap((0 ..< tree.nodes.count)
            .first { tree.name(of: $0) == "wanderer.bin" })
        try FileManager.default.moveItem(at: file, to: elsewhere)

        tree.remove(node)
        let inferred = tree.size(of: freeIdx)
        XCTAssertGreaterThan(inferred, freeBefore + 5_000_000,
                             "remove() on its own credits the free block")

        tree.refreshVolumeAccounting()
        let measured = tree.size(of: freeIdx)
        XCTAssertLessThan(abs(measured - freeBefore), 1_000_000,
                          "the bytes never left the volume, so free space is unchanged")
        // The file is still on the volume but no longer in the tree, so the
        // shortfall belongs in "Not scanned", which is precisely what it means.
        XCTAssertGreaterThan(tree.size(of: 1), 5_000_000)
    }

    /// Deleting one name of a hard-linked file returns no blocks.  `remove`
    /// credits the free block with the name's share; the refresh takes it back.
    func testHardLinkedDeleteRecoversNothing() throws {
        let a = try write("original.bin", bytes: 6_000_000)
        let b = URL(fileURLWithPath: try mountPoint()).appendingPathComponent("link.bin")
        try FileManager.default.linkItem(at: a, to: b)

        var tree = try FileScanner.scan(path: try mountPoint())
        let freeIdx = try XCTUnwrap(tree.freeSpaceIndex)
        let freeBefore = tree.size(of: freeIdx)

        let node = try XCTUnwrap((0 ..< tree.nodes.count)
            .first { tree.name(of: $0) == "link.bin" })
        XCTAssertTrue(tree.isHardLinked(node))
        try FileManager.default.removeItem(at: b)
        tree.remove(node)
        tree.refreshVolumeAccounting()

        XCTAssertLessThan(abs(tree.size(of: freeIdx) - freeBefore), 1_000_000,
                          "the blocks stay until the last name goes")
    }

    /// A folder scan has no capacity blocks, so there is nothing to refresh and
    /// the call must decline rather than corrupt the totals.
    func testFolderScanDeclinesToRefresh() throws {
        let dir = URL(fileURLWithPath: try mountPoint()).appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 50_000).write(to: dir.appendingPathComponent("x.bin"))

        var tree = try FileScanner.scan(path: dir.path)
        XCTAssertNil(tree.freeSpaceIndex)
        let before = tree.totalSize
        XCTAssertFalse(tree.refreshVolumeAccounting())
        XCTAssertEqual(tree.totalSize, before)
    }
}

/// Charging a deleted item's bytes to the folder they actually moved into.
///
/// Deleting does not destroy anything: the file goes to the Trash, which on a
/// whole-volume scan is a folder the scan already walked.  These check that
/// Plat's patched tree then says exactly what a fresh scan would.
final class ReattributionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-reattr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        try Data(repeating: 4, count: 2_000_000)
            .write(to: root.appendingPathComponent("work/big.bin"))
        try Data(repeating: 4, count: 30_000)
            .write(to: root.appendingPathComponent("work/small.bin"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testPathLookupFindsNodes() throws {
        let tree = try FileScanner.scan(path: root.path)
        XCTAssertEqual(tree.index(ofPath: root.path), 0, "the root resolves to node 0")
        let bin = try XCTUnwrap(tree.index(ofPath: root.appendingPathComponent("bin").path))
        XCTAssertEqual(tree.name(of: bin), "bin")
        let big = try XCTUnwrap(tree.index(ofPath: root.appendingPathComponent("work/big.bin").path))
        XCTAssertEqual(tree.name(of: big), "big.bin")
    }

    func testPathLookupRejectsWhatIsNotThere() throws {
        let tree = try FileScanner.scan(path: root.path)
        XCTAssertNil(tree.index(ofPath: "/etc/hosts"), "outside the scan")
        XCTAssertNil(tree.index(ofPath: root.appendingPathComponent("nope").path))
        XCTAssertNil(tree.index(ofPath: root.path + "-sibling"),
                     "a sibling whose name merely starts the same way")
    }

    /// The property that matters: after moving a file into a folder the scan
    /// knows about, the patched tree matches a fresh scan exactly.
    func testMoveIntoAKnownFolderMatchesARescan() throws {
        var tree = try FileScanner.scan(path: root.path)
        let totalBefore = tree.totalSize

        let node = try XCTUnwrap(tree.index(ofPath: root.appendingPathComponent("work/big.bin").path))
        let bin = try XCTUnwrap(tree.index(ofPath: root.appendingPathComponent("bin").path))

        try FileManager.default.moveItem(at: root.appendingPathComponent("work/big.bin"),
                                         to: root.appendingPathComponent("bin/big.bin"))
        let removal = try XCTUnwrap(tree.remove(node))
        tree.reattribute(removal, to: bin)

        let fresh = try FileScanner.scan(path: root.path)
        XCTAssertEqual(tree.totalSize, totalBefore, "nothing left the tree")
        XCTAssertEqual(tree.totalSize, fresh.totalSize)
        XCTAssertEqual(tree.stats.files, fresh.stats.files)
        XCTAssertEqual(tree.stats.directories, fresh.stats.directories)

        let freshBin = try XCTUnwrap(fresh.index(ofPath: root.appendingPathComponent("bin").path))
        XCTAssertEqual(tree.size(of: bin), fresh.size(of: freshBin),
                       "the destination folder carries the weight")
        let freshWork = try XCTUnwrap(fresh.index(ofPath: root.appendingPathComponent("work").path))
        let work = try XCTUnwrap(tree.index(ofPath: root.appendingPathComponent("work").path))
        XCTAssertEqual(tree.size(of: work), fresh.size(of: freshWork))
    }

    /// Undo has to unwind both halves, or the destination keeps the weight.
    func testUnattributeIsTheExactInverse() throws {
        var tree = try FileScanner.scan(path: root.path)
        let sizes = (0 ..< tree.nodes.count).map { tree.size(of: $0) }
        let statsBefore = tree.stats

        let node = try XCTUnwrap(tree.index(ofPath: root.appendingPathComponent("work/big.bin").path))
        let bin = try XCTUnwrap(tree.index(ofPath: root.appendingPathComponent("bin").path))

        let removal = try XCTUnwrap(tree.remove(node))
        tree.reattribute(removal, to: bin)
        XCTAssertNotEqual((0 ..< tree.nodes.count).map { tree.size(of: $0) }, sizes)

        tree.unattribute(removal, from: bin)
        tree.restore(removal)

        XCTAssertEqual((0 ..< tree.nodes.count).map { tree.size(of: $0) }, sizes)
        XCTAssertEqual(tree.stats, statsBefore)
    }

    /// When the destination is outside the scan there is nothing to charge, and
    /// the tree simply shrinks -- which is also what a rescan would say.
    func testMoveOutOfTheScannedTreeJustShrinks() throws {
        var tree = try FileScanner.scan(path: root.path)
        let node = try XCTUnwrap(tree.index(ofPath: root.appendingPathComponent("work/big.bin").path))
        let away = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-away-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: away) }

        try FileManager.default.moveItem(at: root.appendingPathComponent("work/big.bin"), to: away)
        XCTAssertNil(tree.index(ofPath: away.path), "the destination is not in the tree")
        tree.remove(node)

        let fresh = try FileScanner.scan(path: root.path)
        XCTAssertEqual(tree.totalSize, fresh.totalSize)
        XCTAssertEqual(tree.stats.files, fresh.stats.files)
    }
}
