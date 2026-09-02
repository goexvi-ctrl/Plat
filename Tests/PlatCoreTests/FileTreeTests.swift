import XCTest
@testable import PlatCore

final class FileTreeTests: XCTestCase {

    /// root
    ///   a (dir)
    ///     a1 = 10
    ///     a2 = 20
    ///   b = 5
    private func sampleTree() -> FileTree {
        var names: [UInt8] = []
        func add(_ s: String) -> (UInt32, UInt32) {
            let start = UInt32(names.count)
            names.append(contentsOf: Array(s.utf8))
            return (start, UInt32(s.utf8.count))
        }
        let r = add("root"), a = add("a"), b = add("b"), a1 = add("a1"), a2 = add("a2")
        var nodes: [FileTree.Node] = []
        nodes.append(.init(size: 0, nameOffset: r.0, nameLength: r.1, parent: -1,
                           childStart: 1, childCount: 2, isDirectory: true))
        nodes.append(.init(size: 0, nameOffset: a.0, nameLength: a.1, parent: 0,
                           childStart: 3, childCount: 2, isDirectory: true))
        nodes.append(.init(size: 5, nameOffset: b.0, nameLength: b.1, parent: 0))
        nodes.append(.init(size: 10, nameOffset: a1.0, nameLength: a1.1, parent: 1))
        nodes.append(.init(size: 20, nameOffset: a2.0, nameLength: a2.1, parent: 1))
        return FileTree(nodes: nodes, names: names, rootPath: "/tmp/root", stats: ScanStats())
    }

    func testNamesAndChildren() {
        let t = sampleTree()
        XCTAssertEqual(t.name(of: 0), "root")
        XCTAssertEqual(t.name(of: 4), "a2")
        XCTAssertEqual(Array(t.children(of: 0)), [1, 2])
        XCTAssertEqual(Array(t.children(of: 1)), [3, 4])
        XCTAssertTrue(t.children(of: 2).isEmpty)
    }

    func testRollUpSizes() {
        var t = sampleTree()
        t.rollUpSizes()
        XCTAssertEqual(t.size(of: 1), 30, "directory a should total its two files")
        XCTAssertEqual(t.size(of: 0), 35, "root should total everything")
        XCTAssertEqual(t.totalSize, 35)
    }

    func testRollUpIsIdempotentPerScan() {
        var t = sampleTree()
        t.rollUpSizes()
        let once = t.totalSize
        // Rolling up twice double-counts by design; the scanner calls it exactly
        // once. This pins the contract so a future caller cannot quietly change it.
        t.rollUpSizes()
        XCTAssertGreaterThan(t.totalSize, once)
    }

    func testPathReconstruction() {
        let t = sampleTree()
        XCTAssertEqual(t.path(of: 0), "/tmp/root")
        XCTAssertEqual(t.path(of: 1), "/tmp/root/a")
        XCTAssertEqual(t.path(of: 4), "/tmp/root/a/a2")
    }

    /// The title bar and breadcrumb are rooted at the folder that was scanned,
    /// not at "/", so they always name the tree as well as the position in it.
    func testDisplayPath() {
        let t = sampleTree()
        XCTAssertEqual(t.displayPath(of: 0), "root")
        XCTAssertEqual(t.displayPath(of: 1), "root/a")
        XCTAssertEqual(t.displayPath(of: 4), "root/a/a2")
        // The absolute path is a different thing and still available.
        XCTAssertEqual(t.path(of: 4), "/tmp/root/a/a2")
    }

    func testDisplayPathSegmentsMatchTheBreadcrumb() {
        let t = sampleTree()
        for node in [0, 1, 2, 3, 4] {
            let segments = t.displayPath(of: node).split(separator: "/").map(String.init)
            let crumbs = t.ancestry(of: node).map { t.name(of: $0) }
            XCTAssertEqual(segments, crumbs,
                           "every element of the displayed path must be a clickable ancestor")
        }
    }

    func testDepthAndAncestry() {
        let t = sampleTree()
        XCTAssertEqual(t.depth(of: 0), 0)
        XCTAssertEqual(t.depth(of: 4), 2)
        XCTAssertEqual(t.ancestry(of: 4), [0, 1, 4])
    }

    /// Both metrics roll up independently.
    func testRollUpCarriesBothMetrics() {
        var t = sampleTree()
        for i in [2, 3, 4] {                 // each file: one 4K block
            t.nodes[i].allocatedSize = 4096
            t.nodes[i].allocatedShared = 4096
        }
        t.rollUpSizes()
        t.metric = .logical
        XCTAssertEqual(t.size(of: 0), 35)
        t.metric = .onDisk
        XCTAssertEqual(t.size(of: 0), 12288)
        XCTAssertEqual(t.size(of: 1), 8192)
    }

    func testSubtreeCounts() {
        let t = sampleTree()
        let all = t.subtreeCounts(of: 0)
        XCTAssertEqual(all.files, 3)
        XCTAssertEqual(all.folders, 1)

        let underA = t.subtreeCounts(of: 1)
        XCTAssertEqual(underA.files, 2)
        XCTAssertEqual(underA.folders, 0)

        // A leaf contains nothing, and does not count itself.
        let leaf = t.subtreeCounts(of: 3)
        XCTAssertEqual(leaf.files, 0)
        XCTAssertEqual(leaf.folders, 0)
    }

    /// Walking a subtree must not recurse: the original's `_free_tree` and
    /// `build_tree` both did, and a deep enough tree overflowed the stack.
    func testDeepTreeDoesNotOverflow() {
        var nodes: [FileTree.Node] = [.init(parent: -1, isDirectory: true)]
        let depth = 200_000
        for i in 1 ... depth {
            nodes[i - 1].childStart = Int32(i)
            nodes[i - 1].childCount = 1
            nodes.append(.init(size: 1, parent: Int32(i - 1), isDirectory: i < depth))
        }
        var t = FileTree(nodes: nodes, names: [], rootPath: "/d", stats: ScanStats())
        t.rollUpSizes()
        XCTAssertEqual(t.totalSize, Int64(depth))
        XCTAssertEqual(t.subtreeCounts(of: 0).files, 1)
        XCTAssertEqual(t.subtreeCounts(of: 0).folders, depth - 1)
    }

    /// Every node must appear after its parent; `rollUpSizes` depends on it.
    func testParentAlwaysPrecedesChild() {
        let t = sampleTree()
        for (i, n) in t.nodes.enumerated() where n.parent >= 0 {
            XCTAssertLessThan(Int(n.parent), i)
        }
    }
}
