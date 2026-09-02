import XCTest
@testable import PlatCore

final class FolderSearchTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-find-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["src/Alpha/node_modules", "src/Beta/node_modules",
                    "docs/Alpha", "src/Alpha/.git", "Empty"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir),
                                   withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 9000).write(
            to: root.appendingPathComponent("src/Alpha/node_modules/big.bin"))
        try Data(repeating: 1, count: 100).write(
            to: root.appendingPathComponent("src/Beta/node_modules/small.bin"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tree() throws -> FileTree { try FileScanner.scan(path: root.path) }

    func testFindsByName() throws {
        let t = try tree()
        let m = t.findFolders(matching: "node_modules")
        XCTAssertEqual(m.count, 2)
        XCTAssertTrue(m.allSatisfy { t.name(of: $0.node) == "node_modules" })
    }

    func testCaseInsensitive() throws {
        let t = try tree()
        XCTAssertEqual(t.findFolders(matching: "ALPHA").count,
                       t.findFolders(matching: "alpha").count)
        XCTAssertEqual(t.findFolders(matching: "alpha").count, 2)
    }

    func testPartialNameMatches() throws {
        let t = try tree()
        XCTAssertFalse(t.findFolders(matching: "mod").isEmpty)
    }

    /// A path fragment narrows by ancestor, so "src/Alpha" excludes "docs/Alpha".
    func testPathFragmentNarrowsByAncestor() throws {
        let t = try tree()
        let m = t.findFolders(matching: "src/Alpha")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.relativePath, "src/Alpha")

        let docs = t.findFolders(matching: "docs/Alpha")
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs.first?.relativePath, "docs/Alpha")
    }

    func testBiggestFirstAmongEqualMatches() throws {
        let t = try tree()
        let m = t.findFolders(matching: "node_modules")
        XCTAssertEqual(m.first?.relativePath, "src/Alpha/node_modules",
                       "the folder using the most space should be offered first")
        XCTAssertGreaterThan(m[0].size, m[1].size)
    }

    func testExactNameOutranksSubstring() throws {
        let t = try tree()
        let m = t.findFolders(matching: "Alpha")
        XCTAssertTrue(m.allSatisfy { $0.isExactName })
    }

    func testHiddenFoldersAreFindable() throws {
        let t = try tree()
        XCTAssertEqual(t.findFolders(matching: ".git").count, 1)
    }

    func testFilesAreNotOffered() throws {
        let t = try tree()
        XCTAssertTrue(t.findFolders(matching: "big.bin").isEmpty,
                      "only folders are navigable destinations")
    }

    func testNoMatchAndEmptyQuery() throws {
        let t = try tree()
        XCTAssertTrue(t.findFolders(matching: "nothing-like-this").isEmpty)
        XCTAssertTrue(t.findFolders(matching: "").isEmpty)
        XCTAssertTrue(t.findFolders(matching: "   ").isEmpty)
    }

    func testExactPathResolution() throws {
        let t = try tree()
        XCTAssertEqual(t.node(atPath: "src/Alpha").map { t.relativePath(of: $0) }, "src/Alpha")
        // Absolute paths inside the scanned tree work too.
        XCTAssertEqual(t.node(atPath: root.path + "/src/Beta").map { t.relativePath(of: $0) },
                       "src/Beta")
        XCTAssertNil(t.node(atPath: "src/Nope"))
        XCTAssertEqual(t.node(atPath: ""), t.root)
    }

    func testLimitIsRespected() throws {
        let t = try tree()
        XCTAssertLessThanOrEqual(t.findFolders(matching: "a", limit: 1).count, 1)
    }
}
