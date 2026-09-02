import Darwin
import XCTest
@testable import PlatCore

/// A tool for finding space to reclaim has to be honest about hard links:
/// deleting one of several names frees nothing.
final class HardLinkTests: XCTestCase {

    private var root: URL!
    private let fileSize = 1_048_576      // 1 MB
    private let linkCount = 5

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-links-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sub"),
                               withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.dat")
        try Data(repeating: 0x41, count: fileSize).write(to: original)
        for i in 1 ..< linkCount {
            try fm.linkItem(at: original, to: root.appendingPathComponent("sub/link\(i).dat"))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLinkCountIsRecorded() throws {
        let t = try FileScanner.scan(path: root.path)
        let files = (0 ..< t.nodes.count).filter { !t.nodes[$0].isDirectory }
        XCTAssertEqual(files.count, linkCount)
        for f in files {
            XCTAssertEqual(Int(t.nodes[f].linkCount), linkCount)
            XCTAssertTrue(t.isHardLinked(f))
        }
        XCTAssertEqual(t.stats.hardLinkedFiles, linkCount)
    }

    /// Splitting must make the total match the space actually occupied, which
    /// is what `du` reports.
    func testSplittingMatchesRealDiskUsage() throws {
        var t = try FileScanner.scan(path: root.path)
        t.metric = .onDisk

        t.splitHardLinks = true
        // Integer division loses at most one byte per link.
        XCTAssertEqual(Double(t.totalSize), Double(fileSize), accuracy: Double(linkCount))

        t.splitHardLinks = false
        XCTAssertEqual(t.totalSize, Int64(fileSize * linkCount),
                       "without splitting, every name is charged in full")
    }

    /// Each name is charged an equal share, so the answer cannot depend on
    /// which worker thread reached which name first.
    func testEachNameCarriesAnEqualShare() throws {
        var t = try FileScanner.scan(path: root.path)
        t.metric = .onDisk
        t.splitHardLinks = true
        let shares = (0 ..< t.nodes.count)
            .filter { !t.nodes[$0].isDirectory }
            .map { t.size(of: $0) }
        XCTAssertEqual(Set(shares).count, 1, "all links should carry the same share")
        XCTAssertEqual(shares.first, Int64(fileSize / linkCount))
    }

    func testSingleThreadedAndParallelAgree() throws {
        var one = try FileScanner.scan(path: root.path, options: ScanOptions(workers: 1))
        var many = try FileScanner.scan(path: root.path, options: ScanOptions(workers: 8))
        one.metric = .onDisk; many.metric = .onDisk
        XCTAssertEqual(one.totalSize, many.totalSize)
    }

    /// Sharing is about disk space only.  An apparent size belongs to the file,
    /// not to how many names point at it.
    func testLogicalSizeIsNeverDivided() throws {
        var t = try FileScanner.scan(path: root.path)
        t.metric = .logical
        for split in [true, false] {
            t.splitHardLinks = split
            XCTAssertEqual(t.totalSize, Int64(fileSize * linkCount),
                           "logical size must ignore the sharing setting")
        }
    }

    func testOrdinaryFilesAreUnaffected() throws {
        try Data(repeating: 2, count: 4096).write(to: root.appendingPathComponent("plain.dat"))
        var t = try FileScanner.scan(path: root.path)
        t.metric = .onDisk
        let plain = try XCTUnwrap((0 ..< t.nodes.count).first { t.name(of: $0) == "plain.dat" })
        XCTAssertEqual(t.nodes[plain].linkCount, 1)
        XCTAssertFalse(t.isHardLinked(plain))
        t.splitHardLinks = true
        let withSplit = t.size(of: plain)
        t.splitHardLinks = false
        XCTAssertEqual(withSplit, t.size(of: plain))
    }

    func testDirectoriesAreNeverMarkedAsLinked() throws {
        let t = try FileScanner.scan(path: root.path)
        for i in 0 ..< t.nodes.count where t.nodes[i].isDirectory {
            XCTAssertFalse(t.isHardLinked(i))
        }
    }
}
