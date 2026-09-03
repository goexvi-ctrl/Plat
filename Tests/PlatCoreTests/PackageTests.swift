import XCTest
@testable import PlatCore

final class PackageTableTests: XCTestCase {

    func testClassification() {
        XCTAssertEqual(Packages.kind(ofExtension: "app"), .code)
        XCTAssertEqual(Packages.kind(ofExtension: "framework"), .code)
        XCTAssertEqual(Packages.kind(ofExtension: "photoslibrary"), .document)
        XCTAssertEqual(Packages.kind(ofExtension: "pages"), .document)
        XCTAssertNil(Packages.kind(ofExtension: "txt"))
        XCTAssertNil(Packages.kind(ofExtension: ""))
    }

    func testClassificationIgnoresCase() {
        XCTAssertEqual(Packages.kind(ofExtension: "APP"), .code)
        XCTAssertEqual(Packages.kind(ofName: "Thing.PrefPane"), .code)
    }

    /// The map and the delete rules must be reading the same table, or Plat
    /// offers to delete pieces of something it drew as one indivisible box.
    func testDeleteRulesAndMapAgree() {
        for ext in Packages.code.union(Packages.document) {
            var a = DeleteAssessment()
            DeleteSafety.classifyForTests(path: "/Users/t/Thing.\(ext)/inner/file",
                                          isDirectory: false, home: "/Users/t", into: &a)
            XCTAssertEqual(a.risk, .danger,
                           "deleting inside a .\(ext) should be dangerous")
        }
    }
}

final class PackageCollapseTests: XCTestCase {

    /// root
    ///   Thing.app (dir)      = 300   -- Contents/MacOS/Thing
    ///   docs (dir)           = 300   -- notes/deep.txt
    private func treeWithBundle() -> FileTree {
        var names: [UInt8] = []
        func add(_ s: String) -> (UInt32, UInt32) {
            let start = UInt32(names.count)
            names.append(contentsOf: Array(s.utf8))
            return (start, UInt32(s.utf8.count))
        }
        let r = add("root"), app = add("Thing.app"), docs = add("docs")
        let contents = add("Contents"), notes = add("notes")
        let bin = add("Thing"), deep = add("deep.txt")

        var nodes: [FileTree.Node] = []
        nodes.append(.init(nameOffset: r.0, nameLength: r.1, parent: -1,
                           childStart: 1, childCount: 2, isDirectory: true))
        nodes.append(.init(nameOffset: app.0, nameLength: app.1, parent: 0,
                           childStart: 3, childCount: 1, isDirectory: true))
        nodes.append(.init(nameOffset: docs.0, nameLength: docs.1, parent: 0,
                           childStart: 4, childCount: 1, isDirectory: true))
        nodes.append(.init(nameOffset: contents.0, nameLength: contents.1, parent: 1,
                           childStart: 5, childCount: 1, isDirectory: true))
        nodes.append(.init(nameOffset: notes.0, nameLength: notes.1, parent: 2,
                           childStart: 6, childCount: 1, isDirectory: true))
        nodes.append(.init(size: 300, nameOffset: bin.0, nameLength: bin.1, parent: 3))
        nodes.append(.init(size: 300, nameOffset: deep.0, nameLength: deep.1, parent: 4))

        var t = FileTree(nodes: nodes, names: names, rootPath: "/r", stats: ScanStats())
        t.rollUpSizes()
        return t
    }

    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)

    func testExtensionIsReadFromTheNameBlob() {
        let t = treeWithBundle()
        XCTAssertEqual(t.fileExtension(of: 1), "app")
        XCTAssertNil(t.fileExtension(of: 2), "docs has no extension")
        XCTAssertEqual(t.fileExtension(of: 6), "txt")
    }

    func testPackageDetection() {
        let t = treeWithBundle()
        XCTAssertTrue(t.isPackage(1))
        XCTAssertEqual(t.packageKind(of: 1), .code)
        XCTAssertFalse(t.isPackage(2), "an ordinary folder is not a package")
        XCTAssertFalse(t.isPackage(6), "a file is not a package, whatever it is called")
    }

    func testCollapsedBundleIsOneLeafBox() {
        var o = TreemapOptions()
        o.collapsePackages = true
        let map = Treemap.build(tree: treeWithBundle(), root: 0, bounds: bounds, options: o)

        let appBoxes = map.boxes.filter { $0.node == 1 }
        XCTAssertEqual(appBoxes.count, 1)
        XCTAssertFalse(appBoxes[0].hasChildren, "a bundle draws as a leaf")
        // Nothing inside it is laid out at all.
        XCTAssertFalse(map.boxes.contains { [3, 5].contains(Int($0.node)) })
        // The ordinary folder beside it is unaffected.
        XCTAssertTrue(map.boxes.contains { $0.node == 4 })
        XCTAssertTrue(map.boxes.contains { $0.node == 6 })
    }

    func testTurningTheSettingOffOpensBundlesUp() {
        var o = TreemapOptions()
        o.collapsePackages = false
        let map = Treemap.build(tree: treeWithBundle(), root: 0, bounds: bounds, options: o)
        XCTAssertTrue(map.boxes.contains { $0.node == 3 }, "Contents is drawn")
        XCTAssertTrue(map.boxes.contains { $0.node == 5 }, "the binary is drawn")
        XCTAssertTrue(map.boxes.first { $0.node == 1 }?.hasChildren ?? false)
    }

    /// The point of collapsing is that the bundle still shows its whole weight.
    func testACollapsedBundleKeepsItsSize() {
        var o = TreemapOptions()
        o.collapsePackages = true
        let t = treeWithBundle()
        let map = Treemap.build(tree: t, root: 0, bounds: bounds, options: o)
        let app = try? XCTUnwrap(map.boxes.first { $0.node == 1 })
        let docs = try? XCTUnwrap(map.boxes.first { $0.node == 2 })
        XCTAssertEqual(t.size(of: 1), 300)
        // Equal sizes, so equal areas -- the bundle is not shrunk by being shut.
        XCTAssertEqual((app?.rect.width ?? 0) * (app!.rect.height),
                       (docs?.rect.width ?? 0) * (docs!.rect.height), accuracy: 1)
    }

    /// Zooming in is the "option to expand into it": `build` starts from the
    /// root's children, so a package that is itself the root is always opened.
    func testZoomingIntoABundleShowsItsContents() {
        var o = TreemapOptions()
        o.collapsePackages = true
        let map = Treemap.build(tree: treeWithBundle(), root: 1, bounds: bounds, options: o)
        XCTAssertTrue(map.boxes.contains { $0.node == 3 },
                      "focusing a bundle must look inside it")
        XCTAssertTrue(map.boxes.contains { $0.node == 5 })
    }

    func testClickingACollapsedBundleSelectsTheBundle() {
        var o = TreemapOptions()
        o.collapsePackages = true
        let map = Treemap.build(tree: treeWithBundle(), root: 0, bounds: bounds, options: o)
        let app = map.boxes.first { $0.node == 1 }!
        let hit = map.hitTest(CGPoint(x: app.rect.midX, y: app.rect.midY))
        XCTAssertEqual(hit, 1, "the whole bundle is the target, not a file in it")
    }
}
