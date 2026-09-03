import CoreGraphics
import XCTest
@testable import PlatCore

final class AppearanceTests: XCTestCase {

    // MARK: Colour encoding

    func testHexRoundTrip() {
        for hex in ["FF0000FF", "00FF0080", "123456AB", "FFFFFFFF", "00000000"] {
            let c = try? XCTUnwrap(ColorRGBA(hex: hex))
            XCTAssertEqual(c?.hex, hex, "round trip failed for \(hex)")
        }
    }

    func testHexAcceptsSixDigitsAndHash() {
        let a = ColorRGBA(hex: "#FF8800")
        XCTAssertEqual(a?.alpha, 1, "six digits means fully opaque")
        XCTAssertEqual(a?.hex, "FF8800FF")
        XCTAssertEqual(ColorRGBA(hex: "ff8800")?.hex, "FF8800FF", "case should not matter")
    }

    func testHexRejectsNonsense() {
        XCTAssertNil(ColorRGBA(hex: ""))
        XCTAssertNil(ColorRGBA(hex: "12345"))
        XCTAssertNil(ColorRGBA(hex: "GGGGGG"))
    }

    /// Translucency has to survive: most treemap fills let the box below show
    /// through, so dropping alpha would visibly change the map.
    func testAlphaSurvivesCGColorRoundTrip() {
        let original = ColorRGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.35)
        let back = ColorRGBA(original.cgColor)
        XCTAssertEqual(back?.alpha ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(back?.red ?? 0, 0.2, accuracy: 0.001)
    }

    // MARK: Overrides

    func testUntouchedSlotsKeepTheBaseTheme() {
        var s = AppearanceSettings()
        s.set(.background, to: ColorRGBA(red: 1, green: 0, blue: 0))
        let themed = s.apply(to: .standard)
        XCTAssertEqual(ColorRGBA(themed.background)?.hex, "FF0000FF")
        // Everything else is untouched.
        XCTAssertEqual(ColorRGBA(themed.collapsed)?.hex,
                       ColorRGBA(RenderTheme.standard.collapsed)?.hex)
        XCTAssertEqual(themed.kinds.count, RenderTheme.standard.kinds.count)
    }

    func testEverySlotCanBeOverridden() {
        var s = AppearanceSettings()
        for slot in ThemeColor.allCases {
            s.set(slot, to: ColorRGBA(red: 0, green: 1, blue: 0, alpha: 1))
        }
        let t = s.apply(to: .standard)
        for c in [t.background, t.container, t.collapsed, t.aggregate,
                  t.linkMark, t.outline, t.label, t.highlight] {
            XCTAssertEqual(ColorRGBA(c)?.hex, "00FF00FF")
        }
    }

    /// Clearing a slot must restore system control, not write a second default.
    func testClearingASlotRestoresTheBase() {
        var s = AppearanceSettings()
        s.set(.label, to: ColorRGBA(red: 1, green: 0, blue: 1))
        s.set(.label, to: nil)
        XCTAssertNil(s.color(.label))
        XCTAssertEqual(ColorRGBA(s.apply(to: .standard).label)?.hex,
                       ColorRGBA(RenderTheme.standard.label)?.hex)
        XCTAssertTrue(s.isDefault)
    }

    func testKindColoursReachTheTheme() {
        var s = AppearanceSettings()
        XCTAssertEqual(s.apply(to: .standard).kinds.count, FileKind.allCases.count)
        s.set(.image, to: ColorRGBA(hex: "00FF00FF")!)
        let t = s.apply(to: .standard)
        XCTAssertEqual(ColorRGBA(t.kinds["image"]!)?.hex, "00FF00FF")
        XCTAssertEqual(ColorRGBA(t.kinds["movie"]!)?.hex, FileKind.movie.defaultColor.hex)
    }

    // MARK: Fonts

    /// The label strip must clear the text, or raising the font size just clips
    /// the labels it was meant to make readable.
    func testLabelHeightGrowsWithTheFont() {
        var s = AppearanceSettings()
        s.mapFontSize = 10
        let small = s.labelHeight
        s.mapFontSize = 20
        XCTAssertGreaterThan(s.labelHeight, small)
        XCTAssertGreaterThan(s.labelHeight, 20, "the strip has to be taller than the text")
    }

    func testDefaultsAreTheShippedLook() {
        let s = AppearanceSettings()
        XCTAssertTrue(s.isDefault)
        XCTAssertTrue(s.colors.isEmpty)
        XCTAssertTrue(s.kindColors.isEmpty)
        XCTAssertEqual(s.mapFontSize, 10)
        XCTAssertEqual(s.labelHeight, 13, "the strip stays 13pt at the default font")
    }

    func testSettingsSurviveEncoding() throws {
        var s = AppearanceSettings()
        s.set(.highlight, to: ColorRGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))
        s.set(.archive, to: ColorRGBA(red: 1, green: 0, blue: 0))
        s.mapFontName = "Menlo"
        s.mapFontSize = 12
        let back = try JSONDecoder().decode(
            AppearanceSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}

final class ExtensionColorTests: XCTestCase {

    func testNormalisationStripsDotsAndCase() {
        XCTAssertEqual(AppearanceSettings.normalizeExtension(".M"), "m")
        XCTAssertEqual(AppearanceSettings.normalizeExtension("Swift"), "swift")
        XCTAssertEqual(AppearanceSettings.normalizeExtension("  .PNG  "), "png")
        XCTAssertEqual(AppearanceSettings.normalizeExtension("..m"), "m")
        XCTAssertEqual(AppearanceSettings.normalizeExtension("   "), "")
    }

    /// Typing ".M" must colour a file called foo.m.
    func testLookupIgnoresDotAndCase() {
        var s = AppearanceSettings()
        s.setExtension(".M", to: ColorRGBA(hex: "FF0000FF")!)
        XCTAssertEqual(s.extensionColor("m")?.hex, "FF0000FF")
        XCTAssertEqual(s.extensionColor(".m")?.hex, "FF0000FF")
        XCTAssertEqual(s.extensionColor("M")?.hex, "FF0000FF")
    }

    func testEmptyExtensionIsRejected() {
        var s = AppearanceSettings()
        s.setExtension("  ", to: ColorRGBA(hex: "FF0000FF")!)
        s.setExtension(".", to: ColorRGBA(hex: "FF0000FF")!)
        XCTAssertTrue(s.extensionColors.isEmpty)
    }

    func testPinnedColoursReachTheTheme() {
        var s = AppearanceSettings()
        s.setExtension("swift", to: ColorRGBA(hex: "112233FF")!)
        let t = s.apply(to: .standard)
        XCTAssertEqual(ColorRGBA(t.extensionColors["swift"]!)?.hex, "112233FF")
        XCTAssertNil(t.extensionColors["m"])
    }

    func testRemovingAPin() {
        var s = AppearanceSettings()
        s.setExtension("m", to: ColorRGBA(hex: "00FF00FF")!)
        s.setExtension("m", to: nil)
        XCTAssertTrue(s.extensionColors.isEmpty)
        XCTAssertTrue(s.isDefault)
    }

    /// The dialog previews with the same resolver the renderer uses, so the two
    /// cannot disagree about what colour a file will be.
    func testEffectiveColorPrefersAPinOverTheKind() {
        var s = AppearanceSettings()
        XCTAssertEqual(s.effectiveColor(forExtension: "png").hex,
                       FileKind.image.defaultColor.hex)
        s.setExtension("png", to: ColorRGBA(hex: "010203FF")!)
        XCTAssertEqual(s.effectiveColor(forExtension: "png").hex, "010203FF")
    }

    func testKindColourCanBeOverriddenAndReset() {
        var s = AppearanceSettings()
        XCTAssertEqual(s.color(for: .movie).hex, FileKind.movie.defaultColor.hex)
        s.set(.movie, to: ColorRGBA(hex: "ABCDEFFF")!)
        XCTAssertEqual(s.color(for: .movie).hex, "ABCDEFFF")
        XCTAssertEqual(ColorRGBA(s.apply(to: .standard).kinds["movie"]!)?.hex, "ABCDEFFF")
        s.set(.movie, to: nil)
        XCTAssertEqual(s.color(for: .movie).hex, FileKind.movie.defaultColor.hex)
        XCTAssertTrue(s.isDefault)
    }

    func testEveryKindHasADistinctDefault() {
        let hexes = FileKind.allCases.map(\.defaultColor.hex)
        XCTAssertEqual(Set(hexes).count, hexes.count, "two kinds share a colour")
    }
}

final class ExtensionUsageTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 40_000).write(to: root.appendingPathComponent("a.swift"))
        try Data(repeating: 1, count: 10_000).write(to: root.appendingPathComponent("b.swift"))
        try Data(repeating: 1, count: 90_000).write(to: root.appendingPathComponent("sub/c.M"))
        try Data(repeating: 1, count: 5_000).write(to: root.appendingPathComponent("noext"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTalliesBySizeAcrossTheWholeTree() throws {
        var tree = try FileScanner.scan(path: root.path)
        tree.metric = .logical
        let usage = tree.extensionUsage()

        XCTAssertEqual(usage.first?.ext, "m", "biggest extension should come first")
        XCTAssertEqual(usage.first?.bytes, 90_000)
        XCTAssertEqual(usage.first?.files, 1)

        let swift = try XCTUnwrap(usage.first { $0.ext == "swift" })
        XCTAssertEqual(swift.bytes, 50_000, "both .swift files should be counted together")
        XCTAssertEqual(swift.files, 2)

        XCTAssertFalse(usage.contains { $0.ext == "noext" })
        XCTAssertNil(usage.first { $0.ext == "M" }, "extensions are folded to lower case")
    }

    func testLimitIsRespected() throws {
        let tree = try FileScanner.scan(path: root.path)
        XCTAssertLessThanOrEqual(tree.extensionUsage(limit: 1).count, 1)
    }

    func testEmptyTree() {
        XCTAssertTrue(FileTree.empty.extensionUsage().isEmpty)
    }
}

/// The kind mapping comes from the system's Uniform Type Identifiers, so these
/// pin the decisions this project makes on top of it rather than re-testing
/// macOS.
final class FileKindTests: XCTestCase {

    func testTheObviousKinds() {
        XCTAssertEqual(FileKind.of(extension: "png"), .image)
        XCTAssertEqual(FileKind.of(extension: "jpg"), .image)
        XCTAssertEqual(FileKind.of(extension: "mp4"), .movie)
        XCTAssertEqual(FileKind.of(extension: "mp3"), .music)
        XCTAssertEqual(FileKind.of(extension: "zip"), .archive)
        XCTAssertEqual(FileKind.of(extension: "pdf"), .pdf)
        XCTAssertEqual(FileKind.of(extension: "app"), .application)
        XCTAssertEqual(FileKind.of(extension: "key"), .presentation)
        XCTAssertEqual(FileKind.of(extension: "docx"), .document)
    }

    /// An interpreted program is the file you run, so it belongs with binaries.
    func testScriptsAreExecutables() {
        for ext in ["py", "js", "sh", "rb", "pl", "zsh", "bash"] {
            XCTAssertEqual(FileKind.of(extension: ext), .executable,
                           ".\(ext) is a program, not prose")
        }
    }

    func testCompiledBinariesAreExecutables() {
        for ext in ["o", "dylib", "exe"] {
            XCTAssertEqual(FileKind.of(extension: ext), .executable)
        }
    }

    /// Source that has to be compiled is not itself the program.
    func testCompiledSourceIsText() {
        for ext in ["swift", "m", "c", "h", "txt", "md", "json", "html"] {
            XCTAssertEqual(FileKind.of(extension: ext), .text,
                           ".\(ext) should be text")
        }
    }

    func testPDFBeatsDocument() {
        XCTAssertEqual(FileKind.of(extension: "pdf"), .pdf,
                       "a PDF is composite content too; the more specific kind wins")
    }

    func testUnknownAndEmpty() {
        XCTAssertEqual(FileKind.of(extension: "zzzznotathing"), .other)
        XCTAssertEqual(FileKind.of(extension: ""), .other)
        XCTAssertEqual(FileKind.of(extension: "."), .other)
    }

    func testLookupIgnoresDotAndCase() {
        XCTAssertEqual(FileKind.of(extension: ".PNG"), .image)
        XCTAssertEqual(FileKind.of(extension: "PnG"), .image)
    }
}
