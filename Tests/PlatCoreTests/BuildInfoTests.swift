import XCTest
@testable import PlatCore

final class BuildInfoTests: XCTestCase {

    func testCleanBuildLine() {
        let b = BuildInfo(version: "0.1.0", commitHash: "8d1bd72", commitDate: "2026-09-02")
        XCTAssertEqual(b.versionString, "Version 0.1.0 (2026-09-02) 8d1bd72")
        XCTAssertFalse(b.isModified)
        XCTAssertEqual(b.buildDetail, "8d1bd72")
    }

    /// A build from a dirty tree corresponds to no commit, so it has to say so.
    func testModifiedBuildLine() {
        let b = BuildInfo(version: "0.1.0", commitHash: "8d1bd72", commitDate: "2026-09-02",
                          treeState: "modified", buildTime: "2026-09-02T18:10:35Z")
        XCTAssertTrue(b.isModified)
        XCTAssertEqual(b.versionString,
                       "Version 0.1.0 (2026-09-02) 8d1bd72 modified 2026-09-02T18:10:35Z")
        XCTAssertEqual(b.buildDetail, "8d1bd72, modified")
    }

    func testModifiedWithoutBuildTime() {
        let b = BuildInfo(version: "0.1.0", commitHash: "abc1234", commitDate: "2026-01-01",
                          treeState: "modified")
        XCTAssertEqual(b.versionString, "Version 0.1.0 (2026-01-01) abc1234 modified")
    }

    /// Built outside a git checkout: still names its version, claims no commit.
    func testNoGitMetadata() {
        let b = BuildInfo(version: "0.1.0")
        XCTAssertEqual(b.versionString, "Version 0.1.0")
        XCTAssertEqual(b.buildDetail, "")
        XCTAssertFalse(b.isModified)
    }

    func testDirtyWithoutAHashStillWarns() {
        let b = BuildInfo(version: "0.1.0", treeState: "modified")
        XCTAssertEqual(b.buildDetail, "modified")
    }

    /// Reading a bundle that carries none of the keys must degrade, not crash.
    func testBundleWithoutKeys() {
        let b = BuildInfo(bundle: Bundle(for: BuildInfoTests.self))
        XCTAssertFalse(b.version.isEmpty)
        XCTAssertFalse(b.isModified)
    }
}
