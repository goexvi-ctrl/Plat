import CoreGraphics
import Foundation

public enum TreemapLayout: String, CaseIterable, Sendable, Codable {
    /// Bruls/Huizing/van Wijk squarified treemap: boxes come out close to
    /// square, so areas are easy to compare and labels usually fit.
    case squarified
    /// The 2004 algorithm: split the entries into two greedily balanced halves
    /// and cut the box in proportion, recursively.  Produces the long thin
    /// slivers the original was known for.
    case classic

    public var displayName: String {
        switch self {
        case .squarified: return "Squarified"
        case .classic:    return "Classic (2004)"
        }
    }
}

public struct TreemapOptions: Sendable {
    /// A box smaller than this in either direction is not subdivided further.
    public var minBoxSize: CGFloat = 10
    /// Height of the label strip reserved at the top of a subdivided box.
    public var labelHeight: CGFloat = 13
    /// Border left around the children of a subdivided box.
    public var padding: CGFloat = 3
    /// How many levels of nesting to draw.  Also the hard stop that keeps a
    /// pathological tree from recursing without bound.
    public var maxDepth: Int = 64
    /// A child whose share of the area falls below this many square points is
    /// not given a box of its own.  Because children are laid out largest
    /// first, everything after the first such child is collapsed into one
    /// "N smaller items" box.  This is what keeps the cost of a layout
    /// proportional to the number of boxes a person can actually see rather
    /// than to the number of files on the disk.
    public var minVisibleArea: CGFloat = 6
    public var layout: TreemapLayout = .squarified

    public init(layout: TreemapLayout = .squarified) { self.layout = layout }
}

public struct TreemapBox: Sendable {
    /// Index into `FileTree.nodes`, or -1 for an aggregate box standing in for
    /// a tail of entries too small to draw individually.
    public var node: Int32
    public var depth: Int32
    public var rect: CGRect
    /// True when this box was subdivided, so it should be drawn as a container
    /// with a label strip rather than as a leaf.
    public var hasChildren: Bool
    /// Number of entries collapsed into this box; 0 for a real node.
    public var aggregatedCount: Int32 = 0

    public var isAggregate: Bool { node < 0 }
}

/// A laid-out treemap.
///
/// The original recomputed this entire layout inside `drawRect:` on every
/// single repaint, and then recomputed it *again* from scratch on every mouse
/// click just to work out which box had been hit.  Here it is computed once per
/// (subtree, size, algorithm) and reused for drawing, hit testing and hover.
public struct Treemap: Sendable {
    public let boxes: [TreemapBox]
    public let bounds: CGRect
    public let root: Int
    public let options: TreemapOptions

    public static let empty = Treemap(boxes: [], bounds: .zero, root: 0, options: TreemapOptions())

    init(boxes: [TreemapBox], bounds: CGRect, root: Int, options: TreemapOptions) {
        self.boxes = boxes
        self.bounds = bounds
        self.root = root
        self.options = options
    }

    /// Lay out the children of `root` to fill `bounds`.
    public static func build(tree: FileTree, root: Int, bounds: CGRect,
                             options: TreemapOptions = TreemapOptions()) -> Treemap {
        guard !tree.isEmpty, root < tree.nodes.count,
              bounds.width > 0, bounds.height > 0 else {
            return Treemap(boxes: [], bounds: bounds, root: root, options: options)
        }
        let builder = Builder(tree: tree, options: options)
        builder.layoutChildren(of: root, in: bounds, depth: 0)
        return Treemap(boxes: builder.boxes, bounds: bounds, root: root, options: options)
    }

    /// The innermost box containing `point`, or nil.
    ///
    /// Boxes are emitted parent-before-child and siblings never overlap, so the
    /// last box in the array that contains the point is by construction the
    /// deepest one.  A backwards scan finds it in one pass -- against a cached
    /// layout of a few thousand visible boxes, rather than the original's full
    /// re-layout of the whole tree per click.
    public func hitTest(_ point: CGPoint) -> Int? {
        guard let box = hitTestBox(point), !box.isAggregate else { return nil }
        return Int(box.node)
    }

    /// As `hitTest`, but also reports aggregate boxes so the UI can say what
    /// they stand for.
    public func hitTestBox(_ point: CGPoint) -> TreemapBox? {
        var i = boxes.count - 1
        while i >= 0 {
            if boxes[i].rect.contains(point) { return boxes[i] }
            i -= 1
        }
        return nil
    }

    public func box(for node: Int) -> TreemapBox? {
        boxes.first { $0.node == Int32(node) }
    }
}

// MARK: - Layout

private struct Item {
    var node: Int32
    var value: Double
}

/// A class, not a struct, so the recursive layout can append to one shared
/// output array without fighting Swift's exclusivity rules on `inout self`.
private final class Builder {
    let tree: FileTree
    let options: TreemapOptions
    var boxes: [TreemapBox] = []

    init(tree: FileTree, options: TreemapOptions) {
        self.tree = tree
        self.options = options
        boxes.reserveCapacity(2048)
    }

    /// Emit `node` as a box, and subdivide it if there is room to be useful.
    func place(node: Int, in rect: CGRect, depth: Int) {
        // A box thinner than a point cannot be seen, cannot be clicked, and
        // costs just as much to draw as a useful one.
        guard rect.width >= 1, rect.height >= 1 else { return }
        // `hasChildren` means "this box was actually subdivided", so it has to
        // agree with the guard in layoutChildren below.  Otherwise a folder cut
        // off by the depth limit draws as a container with nothing inside it.
        let hasRoom = rect.width >= options.minBoxSize * 2
            && rect.height >= options.minBoxSize * 2
            && tree.nodes[node].childCount > 0
            && depth + 1 < options.maxDepth
        boxes.append(TreemapBox(node: Int32(node), depth: Int32(depth),
                                rect: rect, hasChildren: hasRoom))
        guard hasRoom else { return }
        let inner = CGRect(x: rect.minX + options.padding,
                           y: rect.minY + options.labelHeight,
                           width: rect.width - options.padding * 2,
                           height: rect.height - options.labelHeight - options.padding)
        layoutChildren(of: node, in: inner, depth: depth + 1)
    }

    private func emitAggregate(_ rect: CGRect, count: Int, depth: Int) {
        guard count > 0, rect.width >= 1, rect.height >= 1 else { return }
        boxes.append(TreemapBox(node: -1, depth: Int32(depth), rect: rect,
                                hasChildren: false, aggregatedCount: Int32(count)))
    }

    func layoutChildren(of node: Int, in rect: CGRect, depth: Int) {
        guard depth < options.maxDepth,
              rect.width >= options.minBoxSize,
              rect.height >= options.minBoxSize else { return }

        // Zero-length files can never be given a visible area, and dropping them
        // here keeps both algorithms free of degenerate-partition special cases.
        var items: [Item] = []
        let range = tree.children(of: node)
        items.reserveCapacity(range.count)
        for i in range {
            let size = tree.size(of: i)
            if size > 0 { items.append(Item(node: Int32(i), value: Double(size))) }
        }
        guard !items.isEmpty else { return }

        switch options.layout {
        case .squarified:
            items.sort { $0.value > $1.value }
            squarify(items, in: rect, depth: depth)
        case .classic:
            classic(items, in: rect, depth: depth)
        }
    }

    // MARK: Squarified

    private func squarify(_ items: [Item], in initialRect: CGRect, depth: Int) {
        var rect = initialRect
        var remaining = items.reduce(0.0) { $0 + $1.value }
        var i = 0
        let n = items.count

        while i < n {
            guard remaining > 0, rect.width > 0.01, rect.height > 0.01 else { return }
            let area = Double(rect.width) * Double(rect.height)
            let scale = area / remaining
            let side = Double(min(rect.width, rect.height))
            guard side > 0.01 else { return }

            // Items arrive largest-first, so as soon as one is too small to see
            // the whole remaining tail is too.  Collapsing it here is what stops
            // a directory of 200,000 files from producing 200,000 boxes; the
            // items already placed keep their exact proportional areas, because
            // `scale` was derived from the full remaining total.
            if items[i].value * scale < Double(options.minVisibleArea) {
                emitAggregate(rect, count: n - i, depth: depth)
                return
            }

            // Extend the row while doing so improves its worst aspect ratio.
            var j = i
            var sum = 0.0, lo = Double.infinity, hi = 0.0, worst = Double.infinity
            while j < n {
                let a = items[j].value * scale
                let newSum = sum + a
                let newLo = min(lo, a), newHi = max(hi, a)
                guard newSum > 0, newLo > 0 else { j += 1; continue }
                let side2 = side * side
                let sum2 = newSum * newSum
                let candidate = max(side2 * newHi / sum2, sum2 / (side2 * newLo))
                if j == i || candidate <= worst {
                    sum = newSum; lo = newLo; hi = newHi; worst = candidate
                    j += 1
                } else {
                    break
                }
            }
            guard sum > 0, j > i else { return }

            let thickness = CGFloat(sum / side)
            var offset: CGFloat = 0
            if rect.width >= rect.height {
                // A column down the left edge.
                for k in i ..< j {
                    let share = CGFloat(items[k].value * scale / sum) * CGFloat(side)
                    place(node: Int(items[k].node),
                          in: CGRect(x: rect.minX, y: rect.minY + offset,
                                     width: thickness, height: share),
                          depth: depth)
                    offset += share
                }
                rect = CGRect(x: rect.minX + thickness, y: rect.minY,
                              width: max(0, rect.width - thickness), height: rect.height)
            } else {
                // A strip across the top edge.
                for k in i ..< j {
                    let share = CGFloat(items[k].value * scale / sum) * CGFloat(side)
                    place(node: Int(items[k].node),
                          in: CGRect(x: rect.minX + offset, y: rect.minY,
                                     width: share, height: thickness),
                          depth: depth)
                    offset += share
                }
                rect = CGRect(x: rect.minX, y: rect.minY + thickness,
                              width: rect.width, height: max(0, rect.height - thickness))
            }
            remaining -= sum / scale
            i = j
        }
    }

    // MARK: Classic (the 2004 divide_box)

    private func classic(_ items: [Item], in box: CGRect, depth: Int) {
        if items.count == 1 {
            place(node: Int(items[0].node), in: box, depth: depth)
            return
        }
        guard items.count > 1 else { return }

        // Greedy balance: walk the entries in order, adding each to whichever
        // side is currently lighter.  Every item has a positive size here, so
        // both sides always end up non-empty.
        var left: [Item] = [], right: [Item] = []
        var leftSum = 0.0, rightSum = 0.0
        left.reserveCapacity(items.count)
        right.reserveCapacity(items.count)
        for item in items {
            if leftSum <= rightSum {
                left.append(item); leftSum += item.value
            } else {
                right.append(item); rightSum += item.value
            }
        }

        let total = leftSum + rightSum
        guard total > 0 else { return }
        let minSize = options.minBoxSize

        if box.width > box.height {
            let div = (Double(box.width) * leftSum / total).rounded()
            if div < Double(minSize) {
                classic(right, in: box, depth: depth)
            } else if div >= Double(box.width) - Double(minSize) {
                classic(left, in: box, depth: depth)
            } else {
                let d = CGFloat(div)
                classic(left, in: CGRect(x: box.minX, y: box.minY, width: d, height: box.height), depth: depth)
                classic(right, in: CGRect(x: box.minX + d, y: box.minY, width: box.width - d, height: box.height), depth: depth)
            }
        } else {
            let div = (Double(box.height) * leftSum / total).rounded()
            if div < Double(minSize) {
                classic(right, in: box, depth: depth)
            } else if div >= Double(box.height) - Double(minSize) {
                classic(left, in: box, depth: depth)
            } else {
                let d = CGFloat(div)
                classic(left, in: CGRect(x: box.minX, y: box.minY, width: box.width, height: d), depth: depth)
                classic(right, in: CGRect(x: box.minX, y: box.minY + d, width: box.width, height: box.height - d), depth: depth)
            }
        }
    }
}
