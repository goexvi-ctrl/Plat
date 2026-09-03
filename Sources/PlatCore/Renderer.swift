import CoreGraphics
import CoreText
import ImageIO
import Foundation

/// Colours the renderer needs.  Passed in rather than read from AppKit so the
/// same drawing code can paint a window, a bitmap in a test, or a PNG from the
/// command line.
public struct RenderTheme: Sendable {
    public var background: CGColor
    public var container: CGColor
    /// A folder whose contents are not being drawn -- because the depth limit
    /// stopped there, or the box is too small to subdivide.  Filled solidly so
    /// it reads as "there is more in here", not as an empty frame.
    public var collapsed: CGColor
    public var aggregate: CGColor
    /// Corner flag marking a file that has more than one name.
    public var linkMark: CGColor
    public var outline: CGColor
    public var label: CGColor
    public var highlight: CGColor
    /// Capacity blocks: unused space, and space in use that the walk missed.
    public var freeSpace: CGColor
    public var notScanned: CGColor
    /// One colour per file kind, keyed by `FileKind.rawValue`.  A file takes
    /// its kind's colour unless its extension is pinned below.
    public var kinds: [String: CGColor]
    /// Colours pinned to specific extensions, keyed lowercased without the dot.
    /// Consulted before the palette; empty by default, and when it is empty the
    /// renderer skips the lookup entirely.
    public var extensionColors: [String: CGColor] = [:]

    public init(background: CGColor, container: CGColor, collapsed: CGColor,
                aggregate: CGColor, linkMark: CGColor, outline: CGColor,
                label: CGColor, highlight: CGColor,
                freeSpace: CGColor, notScanned: CGColor,
                kinds: [String: CGColor]) {
        self.freeSpace = freeSpace
        self.notScanned = notScanned
        self.linkMark = linkMark
        self.background = background
        self.container = container
        self.collapsed = collapsed
        self.aggregate = aggregate
        self.outline = outline
        self.label = label
        self.highlight = highlight
        self.kinds = kinds
    }

    public static let standard = RenderTheme(
        background: CGColor(gray: 1, alpha: 1),
        container: CGColor(gray: 0.5, alpha: 0.10),
        collapsed: CGColor(red: 0.42, green: 0.53, blue: 0.68, alpha: 0.55),
        aggregate: CGColor(gray: 0.55, alpha: 0.35),
        linkMark: CGColor(red: 0.85, green: 0.12, blue: 0.20, alpha: 0.95),
        outline: CGColor(gray: 0, alpha: 0.28),
        label: CGColor(gray: 0.1, alpha: 1),
        highlight: CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1),
        freeSpace: CGColor(red: 0.86, green: 0.89, blue: 0.92, alpha: 1),
        notScanned: CGColor(red: 0.79, green: 0.75, blue: 0.68, alpha: 1),
kinds: FileKind.allCases.reduce(into: [:]) { $0[$1.rawValue] = $1.defaultColor.cgColor })
}

/// Paints a laid-out `Treemap`.
///
/// Assumes a flipped context (y increasing downwards), which is what an
/// `isFlipped` `NSView` provides and what `renderToImage` sets up.
public struct TreemapRenderer {

    public var theme: RenderTheme
    public var showLabels: Bool
    public var font: CTFont
    /// Mean glyph advance, measured once and used to decide how much of a label
    /// can possibly fit before doing any real text layout.
    private let averageAdvance: CGFloat

    public init(theme: RenderTheme = .standard, showLabels: Bool = true,
                fontName: String = AppearanceSettings.defaultMapFontName,
                fontSize: CGFloat = CGFloat(AppearanceSettings.defaultMapFontSize)) {
        self.theme = theme
        self.showLabels = showLabels
        // Fall back rather than crash if a chosen family has gone away, e.g. a
        // font that was uninstalled after being saved in preferences.
        let requested = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let resolved = CTFontCopyFamilyName(requested) as String
        self.font = resolved.isEmpty
            ? CTFontCreateWithName(AppearanceSettings.defaultMapFontName as CFString, fontSize, nil)
            : requested
        let probe = "abcdefghijklmnopqrstuvwxyz0123456789"
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: probe, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
        self.averageAdvance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            / CGFloat(probe.count)
    }

    public func draw(_ map: Treemap, of tree: FileTree, in context: CGContext,
                     clip: CGRect, highlight: CGRect? = nil) {
        context.setFillColor(theme.background)
        context.fill(clip)
        guard !map.boxes.isEmpty else { return }

        // Pass 1: fills.  Boxes are emitted parent-before-child, so painting in
        // order lays children over their containers with no depth sorting.
        tree.names.withUnsafeBufferPointer { names in
            for box in map.boxes where box.rect.intersects(clip) {
                context.setFillColor(fillColour(for: box, tree: tree, names: names))
                context.fill(box.rect)
            }
        }

        // Pass 2: one path for every outline, so the map costs a single stroke
        // rather than one per box.
        let outlines = CGMutablePath()
        for box in map.boxes where box.rect.intersects(clip) {
            if box.rect.width >= 2 && box.rect.height >= 2 {
                outlines.addRect(box.rect.insetBy(dx: 0.25, dy: 0.25))
            }
        }
        context.setLineWidth(0.5)
        context.setStrokeColor(theme.outline)
        context.addPath(outlines)
        context.strokePath()

        // Hard-link flags.  Deleting one name of a multiply-linked file frees
        // nothing, so a disk-cleanup tool has to say so on the map itself, not
        // only in a panel the user might never open.
        drawLinkMarks(map, of: tree, in: context, clip: clip)

        if showLabels && map.options.labelHeight > 0 {
            drawLabels(map, of: tree, in: context, clip: clip)
        }

        if let highlight {
            context.setStrokeColor(theme.highlight)
            context.setLineWidth(2)
            context.stroke(highlight.insetBy(dx: 1, dy: 1))
        }
    }

    private func fillColour(for box: TreemapBox, tree: FileTree,
                            names: UnsafeBufferPointer<UInt8>) -> CGColor {
        if box.isAggregate { return theme.aggregate }
        let node = tree.nodes[Int(box.node)]
        if node.isSynthetic {
            return tree.synthetic(Int(box.node)) == .freeSpace
                ? theme.freeSpace : theme.notScanned
        }
        if box.hasChildren { return theme.container }
        // A folder we chose not to open: show it as a solid block.
        if node.isDirectory { return node.childCount > 0 ? theme.collapsed : theme.container }
        // A pinned extension wins; otherwise the file takes its kind's colour.
        let ext = extensionKey(of: node, in: names)
        if let ext, let pinned = theme.extensionColors[ext] { return pinned }
        let kind = ext.map(FileKind.of(extension:)) ?? .other
        return theme.kinds[kind.rawValue] ?? kind.defaultColor.cgColor
    }

    private func extensionKey(of node: FileTree.Node,
                              in names: UnsafeBufferPointer<UInt8>) -> String? {
        let lo = Int(node.nameOffset)
        let hi = lo + Int(node.nameLength)
        var dot = -1
        var i = hi - 1
        while i > lo {
            if names[i] == UInt8(ascii: ".") { dot = i; break }
            i -= 1
        }
        guard dot >= 0, dot + 1 < hi else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hi - dot - 1)
        for j in (dot + 1) ..< hi {
            let b = names[j]
            bytes.append(b >= 65 && b <= 90 ? b + 32 : b)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func drawLinkMarks(_ map: Treemap, of tree: FileTree,
                               in context: CGContext, clip: CGRect) {
        var marked = false
        for box in map.boxes {
            guard !box.isAggregate, box.rect.intersects(clip),
                  box.rect.width >= 7, box.rect.height >= 7,
                  tree.isHardLinked(Int(box.node)) else { continue }
            if !marked {
                context.setFillColor(theme.linkMark)
                marked = true
            }
            // A small triangle tucked into the top-right corner.
            let side = min(7, min(box.rect.width, box.rect.height) * 0.45)
            let x = box.rect.maxX - 1, y = box.rect.minY + 1
            context.move(to: CGPoint(x: x - side, y: y))
            context.addLine(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x, y: y + side))
            context.closePath()
            context.fillPath()
        }
    }

    private func drawLabels(_ map: Treemap, of tree: FileTree,
                            in context: CGContext, clip: CGRect) {
        context.saveGState()
        // The context is flipped, so glyphs need their own flip to be upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let ascent = CTFontGetAscent(font)
        let labelHeight = map.options.labelHeight

        for box in map.boxes {
            let r = box.rect
            guard r.height >= labelHeight, r.width >= 26, r.intersects(clip) else { continue }
            // A leaf smaller than its own caption is just noise.
            guard box.hasChildren || r.height >= 16 else { continue }

            let text: String
            if box.isAggregate {
                text = "\(ByteFormat.count(Int(box.aggregatedCount))) smaller items"
            } else {
                text = "\(tree.name(of: Int(box.node)))  \(ByteFormat.compact(tree.size(of: Int(box.node))))"
            }

            let budget = Int((r.width - 6) / averageAdvance)
            guard budget >= 3 else { continue }
            let shown = text.count <= budget
                ? text
                : String(text.prefix(max(1, budget - 1))) + "\u{2026}"

            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: shown, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: theme.label,
                ]))
            context.textPosition = CGPoint(x: r.minX + 3, y: r.minY + ascent + 1)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

extension TreemapRenderer {
    /// Render a treemap straight to a bitmap -- no window, no AppKit.  Used by
    /// the command-line renderer and to check drawing without a display.
    public static func renderToPNG(tree: FileTree, root: Int, size: CGSize,
                                   options: TreemapOptions = TreemapOptions(),
                                   theme: RenderTheme = .standard,
                                   scale: CGFloat = 2) -> Data? {
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Flip so the renderer's top-left origin matches.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        let bounds = CGRect(origin: .zero, size: size)
        let map = Treemap.build(tree: tree, root: root, bounds: bounds, options: options)
        TreemapRenderer(theme: theme).draw(map, of: tree, in: context, clip: bounds)

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
