import Foundation

/// A scanned directory tree, stored as two flat buffers.
///
/// The 2004 version gave every file its own `entry_t`, every directory its own
/// `malloc`'d child array, and every name a slot in a global intern table so
/// that names could be compared by pointer.  Nothing here needs pointer
/// comparison, and a million small allocations cost more than the walk itself,
/// so the whole tree is a single `Node` array plus a single blob of UTF-8 name
/// bytes.  Children of a node are contiguous, which makes the common operations
/// -- summing sizes, laying out one level, walking to the root -- linear sweeps
/// over cache-friendly memory.
///
/// Nodes are always appended parent-before-children, so `parent < index` holds
/// for every node.  `rollUpSizes` relies on that.
/// Which of the two sizes a file has should be shown.
public enum SizeMetric: String, CaseIterable, Sendable, Codable {
    /// Blocks actually committed on disk (`ATTR_FILE_ALLOCSIZE`).  This is what
    /// `du` reports and what you get back by deleting the file, so it is the
    /// default: a 500 GB sparse disk image occupying 4 KB should look like 4 KB.
    case onDisk
    /// The file's apparent length (`ATTR_FILE_TOTALSIZE`, data + resource fork).
    /// What the original measured, and what Finder calls "Size".
    case logical

    public var displayName: String {
        switch self {
        case .onDisk:  return "Size on disk"
        case .logical: return "Logical size"
        }
    }

    public var shortName: String {
        switch self {
        case .onDisk:  return "on disk"
        case .logical: return "logical"
        }
    }
}

public struct FileTree: Sendable {

    public struct Node: Sendable {
        /// Blocks committed on disk, counting every hard link in full.
        public var allocatedSize: Int64
        /// Blocks committed on disk, with a hard-linked file's blocks divided
        /// evenly among its names.  Summed over a whole volume this is the
        /// truth; `allocatedSize` over-counts.  Kept alongside rather than
        /// derived, so the setting can be toggled without rescanning or
        /// re-rolling the tree.
        public var allocatedShared: Int64
        /// Apparent length, for this file or everything beneath this directory.
        /// Never divided -- an apparent size is a property of the file, not of
        /// how many names point at it.
        public var logicalSize: Int64
        /// Offset and length of this node's name in `names`.
        public var nameOffset: UInt32
        /// NAME_MAX is 255 on macOS, so 16 bits is ample -- and it leaves room
        /// for `linkCount` without growing the node.
        public var nameLength: UInt16
        /// Number of directory entries pointing at this file; 1 for almost
        /// everything, 0 for directories.
        public var linkCount: UInt16
        /// Index of the parent node, or -1 for the root.
        public var parent: Int32
        /// Index of the first child; children occupy `childStart ..< childStart + childCount`.
        public var childStart: Int32
        public var childCount: Int32
        public var isDirectory: Bool
        /// A block standing for capacity rather than for a file on disk -- free
        /// space, or space the scan could not account for.  It has no path.
        public var isSynthetic: Bool
        /// Deleted since the scan.  The node stays in the array -- children are
        /// contiguous ranges, so compacting it out would invalidate every index
        /// above it -- but its sizes are zero and traversals stop here.  Free
        /// alongside the two flags already present: Node is 46 bytes of fields
        /// padded to 48 either way.
        public var isDeleted: Bool = false

        public init(size: Int64 = 0, logicalSize: Int64? = nil,
                    allocatedShared: Int64? = nil, linkCount: UInt16 = 1,
                    nameOffset: UInt32 = 0, nameLength: UInt32 = 0,
                    parent: Int32 = -1, childStart: Int32 = 0, childCount: Int32 = 0,
                    isDirectory: Bool = false, isSynthetic: Bool = false) {
            self.allocatedSize = size
            self.allocatedShared = allocatedShared ?? size
            self.logicalSize = logicalSize ?? size
            self.linkCount = linkCount
            self.nameOffset = nameOffset
            self.nameLength = UInt16(min(nameLength, UInt32(UInt16.max)))
            self.parent = parent
            self.childStart = childStart
            self.childCount = childCount
            self.isDirectory = isDirectory
            self.isSynthetic = isSynthetic
        }
    }

    public var nodes: [Node]
    public var names: [UInt8]
    public var rootPath: String
    public var stats: ScanStats
    /// Capacity of the volume, when the scan covered a whole one.
    public var volume: VolumeInfo?
    /// Which size the tree reports.  Changing it is free -- all variants were
    /// measured during the scan.
    public var metric: SizeMetric = .onDisk
    /// Divide a hard-linked file's disk usage among its names.  Only affects
    /// `.onDisk`: an apparent size is a property of the file, not of how many
    /// names point at it.
    public var splitHardLinks = true
    /// Bumped whenever a node is removed or restored.  A deletion changes sizes
    /// without changing the node count, so the views need something to compare
    /// that says "the layout you cached is stale".
    public private(set) var revision = 0

    public init(nodes: [Node], names: [UInt8], rootPath: String, stats: ScanStats,
                metric: SizeMetric = .onDisk, splitHardLinks: Bool = true) {
        self.nodes = nodes
        self.names = names
        self.rootPath = rootPath
        self.stats = stats
        self.metric = metric
        self.splitHardLinks = splitHardLinks
    }

    /// The size of a node under the tree's current metric and sharing setting.
    public func size(of index: Int) -> Int64 {
        guard metric == .onDisk else { return nodes[index].logicalSize }
        return splitHardLinks ? nodes[index].allocatedShared : nodes[index].allocatedSize
    }

    /// True when this file is reachable under more than one name, so deleting
    /// this one frees nothing.
    public func isHardLinked(_ index: Int) -> Bool {
        !nodes[index].isDirectory && nodes[index].linkCount > 1
    }

    public static let empty = FileTree(nodes: [], names: [], rootPath: "", stats: ScanStats())

    public var isEmpty: Bool { nodes.isEmpty }

    /// The root is always node 0.
    public var root: Int { 0 }

    public var totalSize: Int64 { nodes.isEmpty ? 0 : size(of: 0) }

    public func children(of index: Int) -> Range<Int> {
        let n = nodes[index]
        let start = Int(n.childStart)
        return start ..< (start + Int(n.childCount))
    }

    public func name(of index: Int) -> String {
        let n = nodes[index]
        guard n.nameLength > 0 else { return "" }
        let lo = Int(n.nameOffset)
        let hi = lo + Int(n.nameLength)
        return names.withUnsafeBufferPointer { buf in
            String(decoding: UnsafeBufferPointer(rebasing: buf[lo..<hi]), as: UTF8.self)
        }
    }

    /// The lowercased extension of a node's name, read straight out of the
    /// name blob.  Avoids building the whole name just to look at the few bytes
    /// after the last dot.
    public func fileExtension(of index: Int) -> String? {
        let n = nodes[index]
        let lo = Int(n.nameOffset)
        let hi = lo + Int(n.nameLength)
        var dot = -1
        var i = hi - 1
        // A leading dot makes a hidden file, not an extension, so stop above lo.
        while i > lo {
            if names[i] == UInt8(ascii: ".") { dot = i; break }
            i -= 1
        }
        guard dot >= 0, dot + 1 < hi else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hi - dot - 1)
        for j in (dot + 1) ..< hi {
            let b = names[j]
            bytes.append(b >= 65 && b <= 90 ? b + 32 : b)   // ASCII lowercase
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Whether this node is a directory macOS presents as a single object -- an
    /// application, a Photos library, a Pages document.
    public func packageKind(of index: Int) -> PackageKind? {
        let n = nodes[index]
        guard n.isDirectory, !n.isSynthetic else { return nil }
        return fileExtension(of: index).flatMap(Packages.kind(ofExtension:))
    }

    public func isPackage(_ index: Int) -> Bool { packageKind(of: index) != nil }

    /// Full filesystem path of a node, rebuilt by walking to the root.
    /// O(depth); nothing stores paths, which is what keeps a multi-million-node
    /// scan inside a few hundred megabytes.
    public func path(of index: Int) -> String {
        var parts: [String] = []
        var i = index
        while i >= 0 {
            let n = nodes[i]
            if n.parent < 0 { break }
            parts.append(name(of: i))
            i = Int(n.parent)
        }
        guard !parts.isEmpty else { return rootPath }
        let base = rootPath == "/" ? "" : rootPath
        return base + "/" + parts.reversed().joined(separator: "/")
    }

    public func depth(of index: Int) -> Int {
        var d = 0
        var i = index
        while nodes[i].parent >= 0 {
            i = Int(nodes[i].parent)
            d += 1
        }
        return d
    }

    /// The chain from the root down to `index`, inclusive.
    public func ancestry(of index: Int) -> [Int] {
        var chain: [Int] = []
        var i = index
        while true {
            chain.append(i)
            let p = nodes[i].parent
            if p < 0 { break }
            i = Int(p)
        }
        return chain.reversed()
    }

    /// The chain of names from the scanned folder down to `index`, joined for
    /// display: "claude/src/Plat".
    ///
    /// Unlike `path(of:)` this is rooted at the folder that was scanned rather
    /// than at "/", so the title bar always says which tree you are looking at
    /// as well as where you are inside it.
    public func displayPath(of index: Int) -> String {
        ancestry(of: index).map { name(of: $0) }.joined(separator: "/")
    }

    /// The two capacity blocks, when the scan covered a whole volume.
    ///
    /// They are reserved in this order in the root's first two child slots by
    /// `FileScanner.scan`, which is what makes an index test enough; a test
    /// pins the order so a future change cannot quietly reverse them.
    public enum Synthetic: Sendable, Equatable { case notScanned, freeSpace }

    public func synthetic(_ index: Int) -> Synthetic? {
        guard index < nodes.count, nodes[index].isSynthetic else { return nil }
        switch index {
        case 1: return .notScanned
        case 2: return .freeSpace
        default: return nil
        }
    }

    /// Count everything beneath a node.
    ///
    /// Children are contiguous but a whole *subtree* is not (nodes are laid out
    /// breadth-first), so this walks with an explicit stack rather than
    /// recursing -- a deep tree must not be able to overflow the stack, which
    /// the original's recursive `_free_tree` and `build_tree` both could.
    public func subtreeCounts(of index: Int) -> (files: Int, folders: Int) {
        var files = 0, folders = 0
        var stack = [index]
        stack.reserveCapacity(64)
        while let i = stack.popLast() {
            let node = nodes[i]
            // A deleted subtree is unreachable, and a capacity block is not an
            // item on disk; neither belongs in a count of what a folder holds.
            if node.isDeleted || node.isSynthetic { continue }
            if i != index {
                if node.isDirectory { folders += 1 } else { files += 1 }
            }
            let start = Int(node.childStart)
            if node.childCount > 0 {
                stack.append(contentsOf: start ..< (start + Int(node.childCount)))
            }
        }
        return (files, folders)
    }

    /// Propagate file sizes up into their directories.
    ///
    /// Because children are always appended after their parent, a single
    /// backwards sweep is enough -- no recursion, no second traversal, and no
    /// risk of blowing the stack on a pathologically deep tree (the original
    /// recursed once per directory in `build_tree`).
    public mutating func rollUpSizes() {
        guard nodes.count > 1 else { return }
        nodes.withUnsafeMutableBufferPointer { buf in
            var i = buf.count - 1
            while i > 0 {
                let parent = Int(buf[i].parent)
                if parent >= 0 {
                    buf[parent].allocatedSize += buf[i].allocatedSize
                    buf[parent].allocatedShared += buf[i].allocatedShared
                    buf[parent].logicalSize += buf[i].logicalSize
                }
                i -= 1
            }
        }
    }

    // MARK: Deletion

    /// Everything needed to undo one removal.  Restoring is O(depth) rather
    /// than O(subtree) because a removal zeroes only the node itself; its
    /// children keep their sizes and are simply never reached.
    public struct Removal: Sendable, Equatable {
        public var node: Int
        public var allocatedSize: Int64
        public var allocatedShared: Int64
        public var logicalSize: Int64
        public var files: Int
        public var folders: Int
        /// Where it was, so the caller can put the file back.
        public var path: String
    }

    /// Take a node out of the tree after its file has gone to the Trash.
    ///
    /// The three sizes come off every ancestor and go onto the free-space
    /// block, so the root still totals the volume's capacity and the map
    /// redraws with a visibly larger free area -- which is the whole point of
    /// deleting something.
    ///
    /// The free block is credited with the same figure that was subtracted,
    /// which keeps the root exactly invariant under every metric.  For a
    /// hard-linked name that overstates the real gain: the blocks stay until
    /// the last name goes, and the surviving names' shares should grow to
    /// match.  Plat does not know where those other names are without another
    /// scan, so it says so in the confirmation instead of guessing here.
    @discardableResult
    public mutating func remove(_ index: Int) -> Removal? {
        guard index > 0, index < nodes.count else { return nil }
        let n = nodes[index]
        guard !n.isSynthetic, !n.isDeleted else { return nil }
        let counts = subtreeCounts(of: index)
        let removal = Removal(node: index,
                              allocatedSize: n.allocatedSize,
                              allocatedShared: n.allocatedShared,
                              logicalSize: n.logicalSize,
                              files: counts.files + (n.isDirectory ? 0 : 1),
                              folders: counts.folders + (n.isDirectory ? 1 : 0),
                              path: path(of: index))
        nodes[index].isDeleted = true
        apply(removal, sign: -1)
        return removal
    }

    /// Put a removal back, after the file itself has been recovered.
    public mutating func restore(_ removal: Removal) {
        guard removal.node < nodes.count, nodes[removal.node].isDeleted else { return }
        nodes[removal.node].isDeleted = false
        apply(removal, sign: 1)
    }

    /// Move one removal's weight on or off the ancestors and the free block.
    private mutating func apply(_ r: Removal, sign: Int64) {
        let allocated = r.allocatedSize * sign
        let shared = r.allocatedShared * sign
        let logical = r.logicalSize * sign

        // The node itself holds its size only while it is present.
        nodes[r.node].allocatedSize = sign < 0 ? 0 : r.allocatedSize
        nodes[r.node].allocatedShared = sign < 0 ? 0 : r.allocatedShared
        nodes[r.node].logicalSize = sign < 0 ? 0 : r.logicalSize

        var i = Int(nodes[r.node].parent)
        while i >= 0 {
            nodes[i].allocatedSize += allocated
            nodes[i].allocatedShared += shared
            nodes[i].logicalSize += logical
            i = Int(nodes[i].parent)
        }

        // Give the space back to the free block, and to the root along with it,
        // so the root stays equal to the volume's capacity.
        if let free = freeSpaceIndex {
            nodes[free].allocatedSize -= allocated
            nodes[free].allocatedShared -= shared
            nodes[free].logicalSize -= logical
            nodes[root].allocatedSize -= allocated
            nodes[root].allocatedShared -= shared
            nodes[root].logicalSize -= logical
        }

        revision += 1
        stats.files += r.files * Int(sign)
        stats.directories += r.folders * Int(sign)
        stats.allocatedBytes += allocated
        stats.sharedBytes += shared
        stats.totalBytes += logical
    }

    /// Index of the free-space block, when the scan covered a whole volume.
    public var freeSpaceIndex: Int? {
        synthetic(2) == .freeSpace ? 2 : nil
    }

    public func isDeleted(_ index: Int) -> Bool {
        index >= 0 && index < nodes.count && nodes[index].isDeleted
    }

    /// True when this node or anything above it has been deleted, so it is no
    /// longer reachable on disk.
    public func isGone(_ index: Int) -> Bool {
        var i = index
        while i >= 0 {
            if nodes[i].isDeleted { return true }
            i = Int(nodes[i].parent)
        }
        return false
    }
}
