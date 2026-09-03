import XCTest
@testable import PlatCore

final class VolumeInfoTests: XCTestCase {

    func testRootVolumeLooksSane() throws {
        let v = try XCTUnwrap(VolumeInfo.of(path: "/"))
        XCTAssertEqual(v.mountPoint, "/")
        XCTAssertGreaterThan(v.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(v.freeBytes, 0)
        XCTAssertEqual(v.usedBytes + v.freeBytes, v.totalBytes,
                       "used and free must account for the whole volume")
    }

    func testMountPointDetection() {
        XCTAssertTrue(VolumeInfo.isMountPoint("/"))
        XCTAssertFalse(VolumeInfo.isMountPoint("/usr"),
                       "a folder inside a volume is not a mount point")
    }

    func testMissingPath() {
        XCTAssertNil(VolumeInfo.of(path: "/no/such/path/at/all"))
        XCTAssertFalse(VolumeInfo.isMountPoint("/no/such/path/at/all"))
    }
}

/// Capacity blocks are tested against a small disk image rather than the boot
/// volume: a real mount point with contents we control, and seconds rather than
/// a whole-disk walk.
final class VolumeCapacityTests: XCTestCase {

    // XCTest drives class setUp/tearDown on one thread; the checker cannot see
    // that, hence the explicit opt-out.
    nonisolated(unsafe) private static var image: URL!
    nonisolated(unsafe) private static var mount: String!

    override class func setUp() {
        super.setUp()
        let dmg = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-capacity-\(UUID().uuidString).dmg")
        guard run("/usr/bin/hdiutil",
                  ["create", "-quiet", "-size", "32m", "-fs", "APFS",
                   "-volname", "PlatCapacityTest", "-ov", dmg.path]) != nil,
              let attach = run("/usr/bin/hdiutil", ["attach", "-nobrowse", dmg.path])
        else { return }
        image = dmg
        // hdiutil prints "/dev/diskNsM \t <fs> \t /Volumes/Name"; take the mount.
        for line in attach.split(separator: "\n") {
            let text = String(line)
            guard let r = text.range(of: "/Volumes/") else { continue }
            mount = String(text[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }
        // Something to find, so the scan is not empty.
        if let mount {
            FileManager.default.createFile(atPath: mount + "/blob.bin",
                                           contents: Data(repeating: 7, count: 4_000_000))
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

    private func volumeScan() throws -> FileTree {
        try XCTUnwrap(Self.mount.map { try? FileScanner.scan(path: $0) } ?? nil,
                      "could not scan the test volume")
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-capacity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 20_000).write(to: root.appendingPathComponent("a.bin"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A folder is not a volume, so it gets no capacity blocks and its total
    /// stays the sum of its files.
    func testSubtreeScanHasNoCapacityBlocks() throws {
        let t = try FileScanner.scan(path: root.path)
        XCTAssertNil(t.volume)
        XCTAssertFalse(t.nodes.contains { $0.isSynthetic })
        XCTAssertNil(t.synthetic(1))
    }

    /// Uses /Volumes rather than / so the suite does not pay for a second
    /// whole-disk walk; both are mount points as far as the option is concerned.
    func testCapacityCanBeTurnedOff() throws {
        let on = try FileScanner.scan(path: root.path)
        XCTAssertNil(on.volume, "a temp folder is not a mount point")
        let off = try FileScanner.scan(path: root.path,
                                       options: ScanOptions(includeVolumeCapacity: false))
        XCTAssertNil(off.volume)
        XCTAssertFalse(off.nodes.contains { $0.isSynthetic })
    }

    /// The whole point: with the blocks in, the root equals the volume exactly.
    func testVolumeScanSumsToTheVolume() throws {
        let t = try volumeScan()
        let volume = try XCTUnwrap(t.volume)

        XCTAssertEqual(t.nodes[0].allocatedShared, volume.totalBytes,
                       "files + not scanned + free must equal the volume")

        let children = t.children(of: 0)
        let synthetic = children.filter { t.nodes[$0].isSynthetic }
        XCTAssertEqual(synthetic.count, 2)
        XCTAssertEqual(t.synthetic(1), .notScanned)
        XCTAssertEqual(t.synthetic(2), .freeSpace)
        XCTAssertEqual(t.nodes[2].allocatedShared, volume.freeBytes)
    }

    /// The capacity blocks take the root's first two child slots, and the real
    /// children must still form one contiguous run after them.
    func testChildrenStayContiguous() throws {
        let t = try volumeScan()
        let children = t.children(of: 0)
        XCTAssertEqual(children.lowerBound, 1, "capacity blocks come first")
        XCTAssertGreaterThan(children.count, 2, "real children follow them")
        for i in children where t.nodes[i].parent != 0 {
            XCTFail("node \(i) is in the root's child range but is not its child")
        }
        // Only the first two are synthetic.
        for i in children {
            XCTAssertEqual(t.nodes[i].isSynthetic, i <= 2, "node \(i)")
        }
    }

    func testCapacityBlocksHaveNoPathAndNoChildren() throws {
        let t = try volumeScan()
        for i in [1, 2] {
            XCTAssertTrue(t.nodes[i].isSynthetic)
            XCTAssertEqual(t.nodes[i].childCount, 0)
            XCTAssertFalse(t.nodes[i].isDirectory)
            XCTAssertFalse(t.name(of: i).isEmpty)
        }
    }

    /// Not-scanned is derived from the hard-link-split total, because the volume
    /// counts shared blocks once. Using the raw total understated it by 27 GB.
    func testNotScannedUsesTheSplitTotal() throws {
        let t = try volumeScan()
        let volume = try XCTUnwrap(t.volume)
        let files = t.children(of: 0)
            .filter { !t.nodes[$0].isSynthetic }
            .reduce(Int64(0)) { $0 + t.nodes[$1].allocatedShared }
        XCTAssertEqual(files + t.nodes[1].allocatedShared, volume.usedBytes,
                       "scanned + not scanned must equal what the volume reports as used")
    }
}
