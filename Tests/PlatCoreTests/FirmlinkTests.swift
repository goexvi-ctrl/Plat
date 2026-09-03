import XCTest
@testable import PlatCore

final class FirmlinkTests: XCTestCase {

    private var hasTable: Bool {
        FileManager.default.fileExists(atPath: "/usr/share/firmlinks")
    }

    // MARK: Containment, which decides whether shadowing applies at all

    func testContainsComparesWholeComponents() {
        XCTAssertTrue(FirmlinkShadow.contains("/", "/anything"))
        XCTAssertTrue(FirmlinkShadow.contains("/Users", "/Users"))
        XCTAssertTrue(FirmlinkShadow.contains("/Users", "/Users/bob"))
        XCTAssertFalse(FirmlinkShadow.contains("/Users", "/UsersOther"),
                       "a prefix that is not a whole component must not match")
        XCTAssertFalse(FirmlinkShadow.contains("/Users/bob", "/Users"))
    }

    // MARK: Which roots get shadowed

    /// Scanning / meets the Data volume twice, so the duplicates are shadowed.
    func testScanningRootShadowsTheDuplicates() throws {
        try XCTSkipUnless(hasTable)
        let f = FirmlinkShadow(root: "/")
        XCTAssertFalse(f.isEmpty, "a scan of / should shadow the firmlink duplicates")
        XCTAssertTrue(f.paths.allSatisfy { $0.hasPrefix("/System/Volumes/Data/") },
                      "only paths under the data volume should ever be shadowed")
        XCTAssertTrue(f.paths.contains { $0.hasSuffix("/Users") })
    }

    /// Scanning the data volume directly must show all of it -- there is no
    /// second path in that scan, so nothing is a duplicate.
    func testScanningTheDataVolumeShadowsNothing() throws {
        try XCTSkipUnless(hasTable)
        XCTAssertTrue(FirmlinkShadow(root: "/System/Volumes/Data").isEmpty)
        XCTAssertTrue(FirmlinkShadow(root: "/System/Volumes/Data/Users").isEmpty)
    }

    func testScanningASubtreeShadowsNothing() throws {
        try XCTSkipUnless(hasTable)
        XCTAssertTrue(FirmlinkShadow(root: "/Users").isEmpty)
        XCTAssertTrue(FirmlinkShadow(root: NSTemporaryDirectory()).isEmpty)
    }

    // MARK: Matching

    func testShadowsMatchesExactPathsOnly() throws {
        try XCTSkipUnless(hasTable)
        let f = FirmlinkShadow(root: "/")
        guard let sample = f.paths.first(where: { $0.hasSuffix("/Users") }) else {
            return XCTFail("expected a shadowed /Users")
        }
        func cstr(_ s: String) -> [CChar] { Array(s.utf8).map { CChar(bitPattern: $0) } + [0] }

        XCTAssertTrue(f.shadows(cstr(sample)))
        // A sibling that is not a firmlink target must still be scanned; losing
        // it would drop real space (.Spotlight-V100 and friends live there).
        XCTAssertFalse(f.shadows(cstr("/System/Volumes/Data/.Spotlight-V100")))
        XCTAssertFalse(f.shadows(cstr("/System/Volumes/Data")))
        XCTAssertFalse(f.shadows(cstr("/Users")), "the familiar path is the one we keep")
        XCTAssertFalse(f.shadows(cstr(sample + "/deeper")),
                       "only the duplicate itself is shadowed, not paths below it")
        XCTAssertFalse(f.shadows(cstr(String(sample.dropLast()))))
    }

    func testEmptyShadowMatchesNothing() {
        let f = FirmlinkShadow()
        XCTAssertTrue(f.isEmpty)
        XCTAssertFalse(f.shadows(Array("/Users".utf8).map { CChar(bitPattern: $0) } + [0]))
    }

    func testMissingTableIsHarmless() {
        let f = FirmlinkShadow(root: "/", tablePath: "/no/such/firmlinks")
        XCTAssertTrue(f.isEmpty, "without the table the scan should still run, just unshadowed")
    }

    // MARK: The property that matters

    /// /Users and /System/Volumes/Data/Users are the same directory. Exactly one
    /// of the two must survive, and it must be the familiar one.
    func testExactlyOneOfTheTwoPathsSurvives() throws {
        try XCTSkipUnless(hasTable)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/System/Volumes/Data/Users"))
        let f = FirmlinkShadow(root: "/")
        func cstr(_ s: String) -> [CChar] { Array(s.utf8).map { CChar(bitPattern: $0) } + [0] }
        let familiar = f.shadows(cstr("/Users"))
        let duplicate = f.shadows(cstr("/System/Volumes/Data/Users"))
        XCTAssertNotEqual(familiar, duplicate, "exactly one path must be shadowed")
        XCTAssertTrue(duplicate, "the duplicate is the one to drop")
    }
}
