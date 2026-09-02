import CoreGraphics
import ImageIO
import XCTest
@testable import PlatCore

/// The drawing path is easy to break in ways that compile fine -- an upside-down
/// text matrix, a flipped context, an all-white frame.  Rendering offscreen
/// catches those without needing a window server.
final class RendererTests: XCTestCase {

    private func sampleTree() throws -> FileTree {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plat-render-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("photos"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("code"),
                               withIntermediateDirectories: true)
        try Data(repeating: 1, count: 400_000).write(to: root.appendingPathComponent("photos/a.jpg"))
        try Data(repeating: 2, count: 250_000).write(to: root.appendingPathComponent("photos/b.jpg"))
        try Data(repeating: 3, count: 180_000).write(to: root.appendingPathComponent("code/main.swift"))
        try Data(repeating: 4, count: 90_000).write(to: root.appendingPathComponent("readme.md"))
        addTeardownBlock { try? fm.removeItem(at: root) }
        return try FileScanner.scan(path: root.path)
    }

    func testRendersNonBlankImage() throws {
        let tree = try sampleTree()
        let size = CGSize(width: 400, height: 300)
        let png = try XCTUnwrap(TreemapRenderer.renderToPNG(
            tree: tree, root: 0, size: size, scale: 1))
        XCTAssertGreaterThan(png.count, 200)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)

        // Count distinct colours: a blank or single-colour frame means the
        // treemap never made it onto the canvas.
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.draw(image, in: CGRect(origin: .zero, size: size))

        var colours = Set<UInt32>()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            colours.insert(UInt32(pixels[i + 1]) << 16
                         | UInt32(pixels[i + 2]) << 8
                         | UInt32(pixels[i + 3]))
        }
        XCTAssertGreaterThan(colours.count, 4,
                             "expected several box colours, got \(colours.count)")
    }

    func testBothLayoutsRender() throws {
        let tree = try sampleTree()
        for layout in TreemapLayout.allCases {
            let png = TreemapRenderer.renderToPNG(
                tree: tree, root: 0, size: CGSize(width: 300, height: 200),
                options: TreemapOptions(layout: layout), scale: 1)
            XCTAssertNotNil(png, "\(layout) produced no image")
        }
    }

    func testEmptyTreeRendersBackgroundOnly() {
        let png = TreemapRenderer.renderToPNG(
            tree: .empty, root: 0, size: CGSize(width: 100, height: 100), scale: 1)
        XCTAssertNotNil(png, "an empty tree should still produce a blank frame, not nil")
    }

    func testDegenerateSizesDoNotCrash() throws {
        let tree = try sampleTree()
        for size in [CGSize(width: 1, height: 1), CGSize(width: 4000, height: 3)] {
            _ = TreemapRenderer.renderToPNG(tree: tree, root: 0, size: size, scale: 1)
        }
    }
}
