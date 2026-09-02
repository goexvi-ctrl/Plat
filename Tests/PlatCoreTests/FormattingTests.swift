import XCTest
@testable import PlatCore

final class FormattingTests: XCTestCase {

    func testBytesBelowOneThousand() {
        XCTAssertEqual(ByteFormat.string(0), "0 B")
        XCTAssertEqual(ByteFormat.string(1), "1 B")
        XCTAssertEqual(ByteFormat.string(999), "999 B")
    }

    /// Regression: the unit index was one step ahead of the number of divisions,
    /// so a 10.4 GB tree was reported as "10.4 TB".
    func testUnitMatchesMagnitude() {
        XCTAssertEqual(ByteFormat.string(1_000), "1.00 KB")
        XCTAssertEqual(ByteFormat.string(1_500), "1.50 KB")
        XCTAssertEqual(ByteFormat.string(999_000), "999 KB")
        XCTAssertEqual(ByteFormat.string(1_000_000), "1.00 MB")
        XCTAssertEqual(ByteFormat.string(1_000_000_000), "1.00 GB")
        XCTAssertEqual(ByteFormat.string(10_436_550_748), "10.4 GB")
        XCTAssertEqual(ByteFormat.string(1_000_000_000_000), "1.00 TB")
        XCTAssertEqual(ByteFormat.string(2_500_000_000_000_000), "2.50 PB")
    }

    /// Two decimals below 10, one below 100, none above -- so a column of sizes
    /// stays about the same width.
    func testPrecisionShrinksAsNumbersGrow() {
        XCTAssertEqual(ByteFormat.string(1_230), "1.23 KB")
        XCTAssertEqual(ByteFormat.string(12_300), "12.3 KB")
        XCTAssertEqual(ByteFormat.string(123_000), "123 KB")
    }

    func testCompactForm() {
        XCTAssertEqual(ByteFormat.compact(512), "512B")
        XCTAssertEqual(ByteFormat.compact(1_500), "1.5K")
        XCTAssertEqual(ByteFormat.compact(10_436_550_748), "10G")
    }
}
