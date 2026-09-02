import Darwin
import XCTest
@testable import PlatCore

final class ScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-test-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("alpha/nested"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("beta"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"),
                               withIntermediateDirectories: true)
        try write("alpha/one.bin", bytes: 1000)
        try write("alpha/nested/two.bin", bytes: 2500)
        try write("beta/three.bin", bytes: 40)
        try write("zero.bin", bytes: 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, bytes: Int) throws {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    func testTotalsAndCounts() throws {
        var tree = try FileScanner.scan(path: root.path)
        XCTAssertEqual(tree.stats.files, 4)
        // root + alpha + nested + beta + empty
        XCTAssertEqual(tree.stats.directories, 5)

        tree.metric = .logical
        XCTAssertEqual(tree.totalSize, 3540)

        // On disk, each non-empty file occupies at least one block, so the
        // allocated total is larger and block-aligned.
        tree.metric = .onDisk
        XCTAssertGreaterThanOrEqual(tree.totalSize, 3540)
        XCTAssertEqual(tree.stats.totalBytes, 3540)
        XCTAssertGreaterThanOrEqual(tree.stats.allocatedBytes, 3540)
    }

    /// The reason on-disk is the default: a sparse file's apparent length says
    /// nothing about the space it is using, and a treemap scaled by it is a lie.
    func testSparseFileMeasuredByAllocation() throws {
        let sparse = root.appendingPathComponent("sparse.img")
        let handle = FileManager.default.createFile(atPath: sparse.path, contents: nil)
        XCTAssertTrue(handle)
        let fd = open(sparse.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        // 500 GB apparent, one byte written at the very end.
        let apparent: off_t = 500_000_000_000
        XCTAssertEqual(lseek(fd, apparent - 1, SEEK_SET), apparent - 1)
        var byte: UInt8 = 0x41
        XCTAssertEqual(Darwin.write(fd, &byte, 1), 1)
        close(fd)

        var tree = try FileScanner.scan(path: root.path)
        let index = try XCTUnwrap((0 ..< tree.nodes.count).first { tree.name(of: $0) == "sparse.img" })

        XCTAssertEqual(tree.nodes[index].logicalSize, Int64(apparent))
        XCTAssertLessThan(tree.nodes[index].allocatedSize, 1_000_000,
                          "a sparse file should occupy almost nothing on disk")

        // The default metric must not let it dominate the tree.
        XCTAssertEqual(tree.metric, .onDisk)
        XCTAssertLessThan(tree.totalSize, 100_000_000)
        tree.metric = .logical
        XCTAssertGreaterThan(tree.totalSize, Int64(apparent))
    }

    func testSingleAndMultiThreadedAgree() throws {
        var one = try FileScanner.scan(path: root.path, options: ScanOptions(workers: 1))
        var many = try FileScanner.scan(path: root.path, options: ScanOptions(workers: 8))
        one.metric = .logical
        many.metric = .logical
        XCTAssertEqual(one.totalSize, many.totalSize)
        XCTAssertEqual(one.stats.files, many.stats.files)
        XCTAssertEqual(one.stats.directories, many.stats.directories)
        XCTAssertEqual(one.nodes.count, many.nodes.count)
    }

    func testStructureIsWellFormed() throws {
        let tree = try FileScanner.scan(path: root.path)
        XCTAssertEqual(tree.nodes[0].parent, -1)
        for (i, n) in tree.nodes.enumerated() where n.parent >= 0 {
            XCTAssertLessThan(Int(n.parent), i, "parent must precede child")
            let siblings = tree.children(of: Int(n.parent))
            XCTAssertTrue(siblings.contains(i), "node \(i) must be in its parent's child range")
        }
        // Every node is reachable exactly once from the root.
        var seen = Set<Int>()
        var stack = [0]
        while let i = stack.popLast() {
            XCTAssertTrue(seen.insert(i).inserted, "node \(i) reached twice")
            stack.append(contentsOf: tree.children(of: i))
        }
        XCTAssertEqual(seen.count, tree.nodes.count)
    }

    func testDirectorySizesAreRolledUp() throws {
        var tree = try FileScanner.scan(path: root.path)
        tree.metric = .logical
        func node(named name: String) -> Int? {
            (0 ..< tree.nodes.count).first { tree.name(of: $0) == name }
        }
        XCTAssertEqual(tree.size(of: node(named: "alpha")!), 3500)
        XCTAssertEqual(tree.size(of: node(named: "nested")!), 2500)
        XCTAssertEqual(tree.size(of: node(named: "beta")!), 40)
        XCTAssertEqual(tree.size(of: node(named: "empty")!), 0)
    }

    func testSymlinksAreNotFollowed() throws {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"),
            withDestinationURL: root)
        var tree = try FileScanner.scan(path: root.path)
        tree.metric = .logical
        XCTAssertEqual(tree.totalSize, 3540, "a symlink to the root must not be counted or followed")
    }

    func testCancellationThrows() throws {
        XCTAssertThrowsError(try FileScanner.scan(path: root.path, isCancelled: { true })) { error in
            guard case ScanError.cancelled = error else {
                return XCTFail("expected .cancelled, got \(error)")
            }
        }
    }

    func testMissingPathThrows() {
        XCTAssertThrowsError(try FileScanner.scan(path: "/no/such/place/at/all"))
    }

    /// Names containing characters the original's fixed `char buf[4096]` path
    /// handling would have been unhappy about.
    func testAwkwardNames() throws {
        let odd = "a b\u{2014}c'\u{00e9}\u{1F600}"
        try write("beta/\(odd)", bytes: 7)
        var tree = try FileScanner.scan(path: root.path)
        tree.metric = .logical
        XCTAssertTrue((0 ..< tree.nodes.count).contains { tree.name(of: $0) == odd })
        XCTAssertEqual(tree.totalSize, 3547)
    }
}
