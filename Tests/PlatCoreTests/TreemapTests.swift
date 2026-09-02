import XCTest
@testable import PlatCore

final class TreemapTests: XCTestCase {

    /// A root with one child per entry in `sizes`.  If `nested` is non-empty the
    /// first child becomes a directory holding those grandchildren.
    private func makeTree(_ sizes: [Int64], nested: [Int64] = []) -> FileTree {
        var nodes: [FileTree.Node] = []
        var names: [UInt8] = []
        func add(_ s: String) -> (UInt32, UInt32) {
            let start = UInt32(names.count)
            names.append(contentsOf: Array(s.utf8))
            return (start, UInt32(s.utf8.count))
        }

        let r = add("root")
        nodes.append(.init(size: 0, nameOffset: r.0, nameLength: r.1, parent: -1,
                           childStart: 1, childCount: Int32(sizes.count), isDirectory: true))
        for (i, size) in sizes.enumerated() {
            let n = add("child\(i)")
            nodes.append(.init(size: size, nameOffset: n.0, nameLength: n.1, parent: 0))
        }
        if !nested.isEmpty {
            nodes[1].isDirectory = true
            nodes[1].childStart = Int32(nodes.count)
            nodes[1].childCount = Int32(nested.count)
            nodes[1].allocatedSize = 0 // a directory's size comes from its children
            nodes[1].logicalSize = 0
            for (i, size) in nested.enumerated() {
                let n = add("grand\(i)")
                nodes.append(.init(size: size, nameOffset: n.0, nameLength: n.1, parent: 1))
            }
        }
        var tree = FileTree(nodes: nodes, names: names, rootPath: "/r", stats: ScanStats())
        tree.rollUpSizes()
        return tree
    }

    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    // MARK: Invariants that must hold for both algorithms

    func testBoxesStayInsideBounds() {
        for layout in TreemapLayout.allCases {
            let t = makeTree([100, 80, 60, 40, 20, 10, 5, 1])
            let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                    options: TreemapOptions(layout: layout))
            XCTAssertFalse(map.boxes.isEmpty, "\(layout)")
            for b in map.boxes {
                XCTAssertGreaterThanOrEqual(b.rect.minX, bounds.minX - 0.001, "\(layout)")
                XCTAssertGreaterThanOrEqual(b.rect.minY, bounds.minY - 0.001, "\(layout)")
                XCTAssertLessThanOrEqual(b.rect.maxX, bounds.maxX + 0.001, "\(layout)")
                XCTAssertLessThanOrEqual(b.rect.maxY, bounds.maxY + 0.001, "\(layout)")
                XCTAssertGreaterThanOrEqual(b.rect.width, 0, "\(layout)")
                XCTAssertGreaterThanOrEqual(b.rect.height, 0, "\(layout)")
            }
        }
    }

    func testSiblingsDoNotOverlap() {
        for layout in TreemapLayout.allCases {
            let t = makeTree([100, 80, 60, 40, 20, 10])
            let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                    options: TreemapOptions(layout: layout))
            let top = map.boxes.filter { $0.depth == 0 }
            for i in 0 ..< top.count {
                for j in (i + 1) ..< top.count {
                    let a = top[i].rect.insetBy(dx: 0.01, dy: 0.01)
                    let b = top[j].rect.insetBy(dx: 0.01, dy: 0.01)
                    XCTAssertFalse(a.intersects(b),
                                   "\(layout): \(top[i].rect) overlaps \(top[j].rect)")
                }
            }
        }
    }

    func testChildBoxesLieInsideTheirParent() {
        for layout in TreemapLayout.allCases {
            let t = makeTree([1000, 10], nested: [500, 300, 200])
            let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                    options: TreemapOptions(layout: layout))
            var rectOf: [Int32: CGRect] = [:]
            for b in map.boxes where !b.isAggregate { rectOf[b.node] = b.rect }
            for b in map.boxes where !b.isAggregate {
                let parent = t.nodes[Int(b.node)].parent
                guard parent > 0, let pr = rectOf[parent] else { continue }
                XCTAssertTrue(pr.insetBy(dx: -0.01, dy: -0.01).contains(b.rect),
                              "\(layout): child \(b.rect) escapes parent \(pr)")
            }
        }
    }

    /// Squarified must give each child area in proportion to its size.
    func testSquarifiedAreasAreProportional() {
        let sizes: [Int64] = [500, 300, 150, 50]
        let t = makeTree(sizes)
        let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                options: TreemapOptions(layout: .squarified))
        let top = map.boxes.filter { $0.depth == 0 && !$0.isAggregate }
        XCTAssertEqual(top.count, sizes.count)
        let totalArea = bounds.width * bounds.height
        let totalSize = Double(sizes.reduce(0, +))
        for b in top {
            let expected = Double(t.size(of: Int(b.node))) / totalSize
            let actual = Double(b.rect.width * b.rect.height / totalArea)
            XCTAssertEqual(actual, expected, accuracy: 0.001,
                           "node \(b.node) got \(actual) of the area, expected \(expected)")
        }
    }

    func testSquarifiedTilesTheWholeArea() {
        let t = makeTree([500, 300, 150, 50, 25, 12, 6, 3])
        let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                options: TreemapOptions(layout: .squarified))
        let covered = map.boxes.filter { $0.depth == 0 }
            .reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        XCTAssertEqual(covered, Double(bounds.width * bounds.height), accuracy: 1.0)
    }

    /// Squarified exists to avoid slivers; check it actually beats the original
    /// on aspect ratio for a spread of sizes.
    func testSquarifiedProducesBetterAspectRatios() {
        let sizes: [Int64] = (1 ... 40).map { Int64($0 * $0) }
        func worstAspect(_ layout: TreemapLayout) -> Double {
            let t = makeTree(sizes)
            let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                    options: TreemapOptions(layout: layout))
            return map.boxes.filter { $0.depth == 0 && !$0.isAggregate }.reduce(1.0) { worst, b in
                guard b.rect.width > 0.5, b.rect.height > 0.5 else { return worst }
                let a = Double(max(b.rect.width, b.rect.height) / min(b.rect.width, b.rect.height))
                return max(worst, a)
            }
        }
        XCTAssertLessThan(worstAspect(.squarified), worstAspect(.classic))
    }

    // MARK: Hit testing

    func testHitTestFindsTheBoxUnderThePoint() {
        for layout in TreemapLayout.allCases {
            let t = makeTree([500, 300, 150, 50])
            let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                    options: TreemapOptions(layout: layout))
            for b in map.boxes.filter({ $0.depth == 0 && !$0.isAggregate }) where b.rect.width > 2 && b.rect.height > 2 {
                let centre = CGPoint(x: b.rect.midX, y: b.rect.midY)
                let hit = map.hitTest(centre)
                XCTAssertNotNil(hit, "\(layout)")
                // The centre of a container lands on a child; either way the hit
                // must be that box or something beneath it.
                let chain = t.ancestry(of: hit!)
                XCTAssertTrue(chain.contains(Int(b.node)),
                              "\(layout): hit \(hit!) is not inside box \(b.node)")
            }
        }
    }

    func testHitTestReturnsTheDeepestBox() {
        let t = makeTree([1000, 1], nested: [600, 400])
        let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                options: TreemapOptions(layout: .squarified))
        guard let grandchild = map.boxes.first(where: { !$0.isAggregate && t.nodes[Int($0.node)].parent == 1 }),
              grandchild.rect.width > 2, grandchild.rect.height > 2 else {
            return XCTFail("expected a nested box to be laid out")
        }
        let hit = map.hitTest(CGPoint(x: grandchild.rect.midX, y: grandchild.rect.midY))
        XCTAssertEqual(hit, Int(grandchild.node),
                       "hit testing must return the innermost box, not its container")
    }

    func testHitTestOutsideBoundsIsNil() {
        let t = makeTree([100, 50])
        let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                options: TreemapOptions(layout: .squarified))
        XCTAssertNil(map.hitTest(CGPoint(x: -5, y: -5)))
        XCTAssertNil(map.hitTest(CGPoint(x: 10_000, y: 10_000)))
    }

    // MARK: Depth limiting

    /// A tree deep enough that the depth limit, not the box size, is what stops
    /// the recursion.
    private func deepTree(levels: Int) -> FileTree {
        var nodes: [FileTree.Node] = [.init(parent: -1, isDirectory: true)]
        var names: [UInt8] = []
        for level in 0 ..< levels {
            let parent = nodes.count - 1
            nodes[parent].childStart = Int32(nodes.count)
            nodes[parent].childCount = 2
            for k in 0 ..< 2 {
                let n = "L\(level)_\(k)"
                let off = UInt32(names.count)
                names.append(contentsOf: Array(n.utf8))
                // The second child is the one that keeps going deeper.
                nodes.append(.init(size: k == 0 ? 1_000 : 1_000_000,
                                   nameOffset: off, nameLength: UInt32(n.utf8.count),
                                   parent: Int32(parent), isDirectory: k == 1))
            }
        }
        var t = FileTree(nodes: nodes, names: names, rootPath: "/deep", stats: ScanStats())
        t.rollUpSizes()
        return t
    }

    func testDepthLimitBoundsNesting() {
        let t = deepTree(levels: 12)
        for limit in 1 ... 6 {
            var o = TreemapOptions(layout: .squarified)
            o.maxDepth = limit
            let map = Treemap.build(tree: t, root: 0, bounds: bounds, options: o)
            XCTAssertFalse(map.boxes.isEmpty, "limit \(limit) drew nothing")
            let deepest = map.boxes.map(\.depth).max() ?? -1
            XCTAssertLessThan(Int(deepest), limit,
                              "limit \(limit) produced a box at depth \(deepest)")
        }
    }

    /// A folder cut off by the limit must not claim to have been subdivided, or
    /// it draws as an empty container instead of a solid block.
    func testCutOffFoldersAreNotMarkedAsContainers() {
        let t = deepTree(levels: 12)
        var o = TreemapOptions(layout: .squarified)
        o.maxDepth = 3
        let map = Treemap.build(tree: t, root: 0, bounds: bounds, options: o)
        let atLimit = map.boxes.filter { $0.depth == 2 && !$0.isAggregate }
        XCTAssertFalse(atLimit.isEmpty)
        for box in atLimit {
            XCTAssertFalse(box.hasChildren,
                           "box at the depth limit still claims children")
        }
        // And something above the limit did get subdivided, so the test means something.
        XCTAssertTrue(map.boxes.contains { $0.depth == 0 && $0.hasChildren })
    }

    func testDeeperLimitNeverDrawsFewerBoxes() {
        let t = deepTree(levels: 12)
        var previous = 0
        for limit in 1 ... 8 {
            var o = TreemapOptions(layout: .squarified)
            o.maxDepth = limit
            let count = Treemap.build(tree: t, root: 0, bounds: bounds, options: o).boxes.count
            XCTAssertGreaterThanOrEqual(count, previous,
                                        "limit \(limit) drew fewer boxes than \(limit - 1)")
            previous = count
        }
    }

    // MARK: Degenerate input

    func testEmptyAndZeroSizedInputsDoNotCrash() {
        XCTAssertTrue(Treemap.build(tree: .empty, root: 0, bounds: bounds).boxes.isEmpty)
        for layout in TreemapLayout.allCases {
            let zeros = makeTree([0, 0, 0])
            let map = Treemap.build(tree: zeros, root: 0, bounds: bounds,
                                    options: TreemapOptions(layout: layout))
            XCTAssertTrue(map.boxes.isEmpty, "\(layout): zero-sized entries get no area")
        }
    }

    func testZeroSizedBoundsProducesNothing() {
        let t = makeTree([10, 20])
        for layout in TreemapLayout.allCases {
            let map = Treemap.build(tree: t, root: 0, bounds: .zero,
                                    options: TreemapOptions(layout: layout))
            XCTAssertTrue(map.boxes.isEmpty, "\(layout)")
        }
    }

    /// The original wrote into `entry_t *data[1024]` on the stack, so a
    /// directory with more than 1024 entries corrupted memory.  Nothing here is
    /// bounded by a fixed array.
    func testVeryWideDirectory() {
        let t = makeTree((1 ... 20_000).map { Int64($0) })
        for layout in TreemapLayout.allCases {
            let map = Treemap.build(tree: t, root: 0, bounds: bounds,
                                    options: TreemapOptions(layout: layout))
            XCTAssertFalse(map.boxes.isEmpty, "\(layout)")
            for b in map.boxes {
                XCTAssertLessThanOrEqual(b.rect.maxX, bounds.maxX + 0.001, "\(layout)")
                XCTAssertLessThanOrEqual(b.rect.maxY, bounds.maxY + 0.001, "\(layout)")
            }
        }
    }

    /// Layout must stay proportional to what is *visible*, not to tree size.
    func testLayoutCostIsBoundedByVisibleArea() {
        let smallTree = makeTree((1 ... 200).map { Int64($0) })
        let largeTree = makeTree((1 ... 200_000).map { Int64($0) })
        let a = Treemap.build(tree: smallTree, root: 0, bounds: bounds).boxes.count
        let b = Treemap.build(tree: largeTree, root: 0, bounds: bounds).boxes.count
        XCTAssertLessThan(b, 5_000,
                          "a 200k-entry directory produced \(b) boxes; pruning is not working")
        XCTAssertGreaterThan(a, 0)
        // The entries that were too small to draw must still be accounted for.
        let large = Treemap.build(tree: largeTree, root: 0, bounds: bounds)
        XCTAssertTrue(large.boxes.contains { $0.isAggregate && $0.aggregatedCount > 0 },
                      "the collapsed tail should be reported, not silently dropped")
    }
}
