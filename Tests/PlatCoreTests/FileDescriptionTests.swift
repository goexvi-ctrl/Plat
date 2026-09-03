import XCTest
@testable import PlatCore

final class FileDescriptionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testDescribesTextByItsContents() throws {
        let f = dir.appendingPathComponent("notes.txt")
        try Data("hello, world\n".utf8).write(to: f)
        let d = try XCTUnwrap(FileDescription.of(path: f.path))
        XCTAssertTrue(d.lowercased().contains("text"), "got \(d)")
    }

    /// The reason to run `file` at all rather than trust the extension.
    func testContentsBeatTheExtension() throws {
        let f = dir.appendingPathComponent("liar.txt")
        // A PNG signature followed by an IHDR chunk header.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data([0x00, 0x00, 0x00, 0x0D]))
        png.append(Data("IHDR".utf8))
        png.append(Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]))
        try png.write(to: f)

        let d = try XCTUnwrap(FileDescription.of(path: f.path))
        XCTAssertTrue(d.contains("PNG"), "a .txt holding a PNG is a PNG: got \(d)")
    }

    /// A name beginning with a dash must not be read as an option.
    func testAwkwardNamesAreNotOptions() throws {
        let f = dir.appendingPathComponent("-b-not-a-flag.txt")
        try Data("plain text here\n".utf8).write(to: f)
        let d = try XCTUnwrap(FileDescription.of(path: f.path))
        XCTAssertTrue(d.lowercased().contains("text"), "got \(d)")
    }

    /// Arguments reach execve as argv, so shell metacharacters and spaces are
    /// just characters.  The proof is that the description still describes this
    /// file's contents: had the string been split on spaces or handed to a
    /// shell, `file` would have been given some other path, or none.
    func testShellMetacharactersInNamesAreInert() throws {
        let f = dir.appendingPathComponent("; rm -rf $HOME && echo .txt")
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data([0x00, 0x00, 0x00, 0x0D]))
        png.append(Data("IHDR".utf8))
        png.append(Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]))
        try png.write(to: f)

        let d = try XCTUnwrap(FileDescription.of(path: f.path),
                              "the whole name must arrive as one argument")
        XCTAssertTrue(d.contains("PNG"), "got \(d)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testMissingFileDescribesNothing() {
        XCTAssertNil(FileDescription.of(path: dir.appendingPathComponent("gone").path))
    }

    func testEmptyFile() throws {
        let f = dir.appendingPathComponent("empty.bin")
        try Data().write(to: f)
        XCTAssertNotNil(FileDescription.of(path: f.path))
    }

    // MARK: Tidying, without running anything

    func testCleanJoinsTheLinesOfAUniversalBinary() {
        let raw = "Mach-O universal binary with 2 architectures:\n" +
                  "[x86_64:Mach-O 64-bit executable x86_64]\n" +
                  "[arm64e:Mach-O 64-bit executable arm64e]\n"
        let out = FileDescription.clean(raw)
        XCTAssertEqual(out, "Mach-O universal binary with 2 architectures:; "
                          + "[x86_64:Mach-O 64-bit executable x86_64]; "
                          + "[arm64e:Mach-O 64-bit executable arm64e]")
    }

    func testCleanRejectsNothingAndErrors() {
        XCTAssertNil(FileDescription.clean("   \n\n "))
        XCTAssertNil(FileDescription.clean("cannot open `/x' (No such file or directory)"))
    }

    func testCleanCapsRunawayOutput() throws {
        let out = try XCTUnwrap(FileDescription.clean(String(repeating: "a", count: 5000)))
        XCTAssertEqual(out.count, FileDescription.limit + 1, "capped, plus the ellipsis")
        XCTAssertTrue(out.hasSuffix("\u{2026}"))
    }
}
