import Darwin
import Foundation

public struct ScanStats: Sendable, Equatable {
    public var files = 0
    public var directories = 0
    public var errors = 0
    /// Apparent bytes (data + resource fork).
    public var totalBytes: Int64 = 0
    /// Bytes actually committed on disk, counting every hard link in full.
    public var allocatedBytes: Int64 = 0
    /// Bytes on disk with hard-linked files divided among their names.
    public var sharedBytes: Int64 = 0
    /// How many files were reachable under more than one name.
    public var hardLinkedFiles = 0
    public var duration: TimeInterval = 0
    public init() {}
}

public struct ScanOptions: Sendable {
    /// Don't descend into other mounted volumes, like the original did.
    public var stayOnOneDevice: Bool
    /// Directories are scanned in parallel; this is how many threads do it.
    public var workers: Int
    /// Bytes handed to `getattrlistbulk` per call.  Bigger means fewer syscalls
    /// and more entries decoded per trip into the kernel.
    public var bufferBytes: Int

    public init(stayOnOneDevice: Bool = true,
                workers: Int = ScanOptions.defaultWorkerCount,
                bufferBytes: Int = 256 << 10) {
        self.stayOnOneDevice = stayOnOneDevice
        self.workers = max(1, workers)
        self.bufferBytes = max(16 << 10, bufferBytes)
    }

    public static var defaultWorkerCount: Int {
        min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    }
}

public enum ScanError: Error, LocalizedError {
    case cannotOpen(String, errno: Int32)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let e):
            return "Cannot read \(path): \(String(cString: strerror(e)))"
        case .cancelled:
            return "Scan cancelled"
        }
    }
}

/// Walks a directory tree into a `FileTree`.
///
/// Two things make this much faster than the 2004 code:
///
///  1. `getattrlistbulk(2)` returns the name, type, device and size of many
///     directory entries in one syscall.  The original did `opendir`/`readdir`
///     plus a separate `getattrlist` for *every single file*, so a directory of
///     1000 files cost ~1000 syscalls; here it costs a handful.
///  2. Directories are scanned by a pool of worker threads.  Filesystem
///     metadata reads are latency-bound, so overlapping them keeps the storage
///     queue full instead of walking the tree one stat at a time.
public enum FileScanner {

    public static func scan(path rootPath: String,
                            options: ScanOptions = ScanOptions(),
                            isCancelled: @escaping @Sendable () -> Bool = { false },
                            progress: (@Sendable (ScanStats) -> Void)? = nil) throws -> FileTree {
        let started = Date()
        let normalized = normalize(rootPath)

        var rootDev: dev_t = 0
        if options.stayOnOneDevice {
            rootDev = try deviceID(of: normalized)
        }

        let state = ScanState(rootDevice: options.stayOnOneDevice ? rootDev : nil,
                              options: options,
                              isCancelled: isCancelled,
                              progress: progress)

        // The root node. Its name is the path we were given; its size is filled
        // in by the roll-up at the end.
        var rootNode = FileTree.Node(parent: -1, isDirectory: true)
        let rootName = Array(displayName(of: normalized).utf8)
        rootNode.nameOffset = 0
        rootNode.nameLength = UInt16(min(rootName.count, Int(UInt16.max)))
        state.names = rootName
        state.nodes = [rootNode]
        state.pending = [DirTask(node: 0, path: cString(normalized))]
        state.stats.directories = 1

        state.run()

        if isCancelled() { throw ScanError.cancelled }
        if let failure = state.failure { throw failure }

        var tree = FileTree(nodes: state.nodes,
                            names: state.names,
                            rootPath: normalized,
                            stats: state.stats)
        tree.rollUpSizes()
        tree.stats.totalBytes = tree.nodes[0].logicalSize
        tree.stats.allocatedBytes = tree.nodes[0].allocatedSize
        tree.stats.sharedBytes = tree.nodes[0].allocatedShared
        tree.stats.duration = Date().timeIntervalSince(started)
        return tree
    }

    // MARK: - Path helpers

    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    static func displayName(of path: String) -> String {
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }

    static func cString(_ s: String) -> [CChar] {
        var a = Array(s.utf8).map { CChar(bitPattern: $0) }
        a.append(0)
        return a
    }

    static func deviceID(of path: String) throws -> dev_t {
        var st = stat()
        if stat(path, &st) != 0 {
            throw ScanError.cannotOpen(path, errno: errno)
        }
        return st.st_dev
    }
}

// MARK: - Work items

struct DirTask {
    var node: Int32
    /// NUL-terminated absolute path.  Only directories carry a path; files never
    /// need one, which is why a scan of five million files allocates roughly one
    /// string per *directory* rather than one per entry.
    var path: [CChar]
}

/// Everything one worker learns about one directory, accumulated without
/// touching any shared state.  It is merged into the tree with a single lock
/// acquisition per directory.
struct DirBatch {
    var nameBytes: [UInt8] = []
    var entries: [(nameOffset: UInt32, nameLength: UInt32, allocated: Int64,
                   shared: Int64, logical: Int64, links: UInt16, isDirectory: Bool)] = []
    /// Paths of the subdirectories in `entries`, in the same relative order.
    var subdirectoryPaths: [[CChar]] = []
    var files = 0
    var directories = 0
    var errors = 0
    var bytes: Int64 = 0
    var allocatedBytes: Int64 = 0
    var sharedBytes: Int64 = 0
    var hardLinked = 0

    mutating func reset() {
        nameBytes.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
        subdirectoryPaths.removeAll(keepingCapacity: true)
        files = 0; directories = 0; errors = 0; bytes = 0
        allocatedBytes = 0; sharedBytes = 0; hardLinked = 0
    }
}

// MARK: - Shared scan state

final class ScanState: @unchecked Sendable {
    private let condition = NSCondition()
    let options: ScanOptions
    let rootDevice: dev_t?
    let isCancelled: @Sendable () -> Bool
    let progress: (@Sendable (ScanStats) -> Void)?

    var nodes: [FileTree.Node] = []
    var names: [UInt8] = []
    var pending: [DirTask] = []
    var stats = ScanStats()
    var failure: Error?

    private var busy = 0
    private var stopped = false
    private var lastReport = Date.distantPast

    init(rootDevice: dev_t?, options: ScanOptions,
         isCancelled: @escaping @Sendable () -> Bool,
         progress: (@Sendable (ScanStats) -> Void)?) {
        self.rootDevice = rootDevice
        self.options = options
        self.isCancelled = isCancelled
        self.progress = progress
    }

    func run() {
        let workers = options.workers
        if workers == 1 {
            worker()
            return
        }
        let group = DispatchGroup()
        // A dedicated concurrent queue: these threads block in syscalls for
        // almost their whole life, so they must not run on the Swift
        // concurrency cooperative pool.
        let queue = DispatchQueue(label: "Plat.scan", attributes: .concurrent)
        for _ in 0 ..< workers {
            queue.async(group: group) { [self] in worker() }
        }
        group.wait()
    }

    private func worker() {
        var batch = DirBatch()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: options.bufferBytes, alignment: 8)
        defer { buffer.deallocate() }

        while true {
            condition.lock()
            while pending.isEmpty && busy > 0 && !stopped {
                condition.wait()
            }
            if stopped || pending.isEmpty {
                condition.unlock()
                break
            }
            if isCancelled() {
                stopped = true
                pending.removeAll()
                condition.broadcast()
                condition.unlock()
                break
            }
            let task = pending.removeLast()
            busy += 1
            condition.unlock()

            batch.reset()
            readDirectory(task, into: &batch, buffer: buffer)

            condition.lock()
            let queuedBefore = pending.count
            let report = commit(batch, parent: task.node)
            busy -= 1
            // Waking every thread on every directory is a thundering herd at
            // this scale; wake them only when there is new work or the scan has
            // finished and they need to see that and exit.
            if pending.count > queuedBefore || busy == 0 {
                condition.broadcast()
            }
            condition.unlock()

            // Deliberately outside the lock: a caller's progress handler must
            // never be able to stall every other worker.
            if let report { progress?(report) }
        }
        // Make sure nobody is left waiting on a condition that can no longer change.
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// Merge one directory's children into the shared tree.  Called with the
    /// lock held; keep it to array appends.  Returns a stats snapshot when it is
    /// time to report progress, so the callback can run after the unlock.
    private func commit(_ batch: DirBatch, parent: Int32) -> ScanStats? {
        guard !batch.entries.isEmpty else {
            return accumulate(batch)
        }
        let nameBase = UInt32(names.count)
        names.append(contentsOf: batch.nameBytes)

        let childStart = Int32(nodes.count)
        nodes[Int(parent)].childStart = childStart
        nodes[Int(parent)].childCount = Int32(batch.entries.count)
        // Do NOT call nodes.reserveCapacity(nodes.count + n) here.  Swift
        // reserves *exactly* what is asked for, which replaces the array's
        // geometric growth with an exact-fit reallocation on almost every
        // directory -- copying the whole array each time, and turning the scan
        // quadratic.  Measured on a plain `append` loop of 800k elements:
        // 1.718s with that reserve, 0.005s without.  Plain `append` already
        // grows geometrically; leave it alone.

        var subdirIndex = 0
        for e in batch.entries {
            let index = Int32(nodes.count)
            nodes.append(FileTree.Node(size: e.allocated,
                                       logicalSize: e.logical,
                                       allocatedShared: e.shared,
                                       linkCount: e.links,
                                       nameOffset: nameBase + e.nameOffset,
                                       nameLength: e.nameLength,
                                       parent: parent,
                                       childStart: 0,
                                       childCount: 0,
                                       isDirectory: e.isDirectory))
            if e.isDirectory {
                pending.append(DirTask(node: index, path: batch.subdirectoryPaths[subdirIndex]))
                subdirIndex += 1
            }
        }
        return accumulate(batch)
    }

    private func accumulate(_ batch: DirBatch) -> ScanStats? {
        stats.files += batch.files
        stats.directories += batch.directories
        stats.errors += batch.errors
        stats.totalBytes += batch.bytes
        stats.allocatedBytes += batch.allocatedBytes
        stats.sharedBytes += batch.sharedBytes
        stats.hardLinkedFiles += batch.hardLinked
        guard progress != nil else { return nil }
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1 else { return nil }
        lastReport = now
        return stats
    }

    // MARK: - The actual directory read

    private func readDirectory(_ task: DirTask, into batch: inout DirBatch,
                               buffer: UnsafeMutableRawPointer) {
        var attrs = FileScanner.bulkAttributeList
        let fd = task.path.withUnsafeBufferPointer { open($0.baseAddress!, O_RDONLY | O_DIRECTORY) }
        guard fd >= 0 else {
            batch.errors += 1
            return
        }
        defer { close(fd) }

        // The parent path, minus its trailing NUL, reused to build child paths.
        var pathPrefix = task.path
        pathPrefix.removeLast()
        if pathPrefix.count == 1 && pathPrefix[0] == CChar(UInt8(ascii: "/")) {
            pathPrefix.removeLast()   // avoid the "//name" case at the volume root
        }

        while true {
            if isCancelled() { return }
            let count = getattrlistbulk(fd, &attrs, buffer, options.bufferBytes,
                                        UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count <= 0 {
                if count < 0 { batch.errors += 1 }
                return
            }
            var p = buffer
            for _ in 0 ..< count {
                let entryLength = Int(p.loadUnaligned(as: UInt32.self))
                decode(p, into: &batch, pathPrefix: pathPrefix)
                p = p.advanced(by: entryLength)
            }
        }
    }

    /// Decode one `getattrlistbulk` record.
    ///
    /// Fields appear in the buffer in a fixed order, and only when the entry's
    /// own `returned` mask says so, so the cursor has to be advanced
    /// conditionally.  Note that `ATTR_CMN_ERROR` is returned immediately after
    /// `ATTR_CMN_RETURNED_ATTRS` -- *before* `ATTR_CMN_NAME` -- even though its
    /// bit value is much higher.
    private func decode(_ entry: UnsafeRawPointer, into batch: inout DirBatch,
                        pathPrefix: [CChar]) {
        var f = entry.advanced(by: MemoryLayout<UInt32>.size)
        let returned = f.loadUnaligned(as: attribute_set_t.self)
        f = f.advanced(by: MemoryLayout<attribute_set_t>.size)

        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let err = f.loadUnaligned(as: UInt32.self)
            f = f.advanced(by: MemoryLayout<UInt32>.size)
            if err != 0 { batch.errors += 1; return }
        }

        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return }
        let ref = f.loadUnaligned(as: attrreference_t.self)
        let namePointer = f.advanced(by: Int(ref.attr_dataoffset))
            .assumingMemoryBound(to: UInt8.self)
        // attr_length counts the terminating NUL.
        let nameLength = Int(ref.attr_length) > 0 ? Int(ref.attr_length) - 1 : 0
        f = f.advanced(by: MemoryLayout<attrreference_t>.size)

        var device: dev_t = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            device = f.loadUnaligned(as: dev_t.self)
            f = f.advanced(by: MemoryLayout<dev_t>.size)
        }

        var objectType: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            objectType = f.loadUnaligned(as: UInt32.self)
            f = f.advanced(by: MemoryLayout<UInt32>.size)
        }

        var links: UInt32 = 1
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            links = f.loadUnaligned(as: UInt32.self)
            f = f.advanced(by: MemoryLayout<UInt32>.size)
        }
        var logical: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 {
            logical = Int64(f.loadUnaligned(as: off_t.self))
            f = f.advanced(by: MemoryLayout<off_t>.size)
        }
        var allocated: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            allocated = Int64(f.loadUnaligned(as: off_t.self))
        }

        guard nameLength > 0 else { return }
        let isDirectory = objectType == VDIR.rawValue
        let isRegular = objectType == VREG.rawValue

        // Sockets, fifos, devices and symlinks occupy no meaningful space, and
        // following a symlink risks counting the same bytes twice or looping.
        guard isDirectory || isRegular else { return }

        if isDirectory, let rootDevice, device != rootDevice {
            return   // a different mounted volume
        }

        let nameOffset = UInt32(batch.nameBytes.count)
        batch.nameBytes.append(contentsOf: UnsafeBufferPointer(start: namePointer, count: nameLength))

        if isDirectory {
            var childPath = pathPrefix
            childPath.append(CChar(UInt8(ascii: "/")))
            childPath.reserveCapacity(childPath.count + nameLength + 1)
            for i in 0 ..< nameLength {
                childPath.append(CChar(bitPattern: namePointer[i]))
            }
            childPath.append(0)
            batch.subdirectoryPaths.append(childPath)
            batch.directories += 1
            batch.entries.append((nameOffset, UInt32(nameLength), 0, 0, 0, 0, true))
        } else {
            // A hard-linked file's blocks belong to all its names at once, so
            // charge each name an equal share.  Dividing rather than giving the
            // whole cost to whichever name is seen first keeps the answer
            // independent of the order the parallel workers happen to run in.
            let clamped = UInt16(min(max(links, 1), UInt32(UInt16.max)))
            let shared = clamped > 1 ? allocated / Int64(clamped) : allocated
            batch.files += 1
            batch.bytes += logical
            batch.allocatedBytes += allocated
            batch.sharedBytes += shared
            if clamped > 1 { batch.hardLinked += 1 }
            batch.entries.append((nameOffset, UInt32(nameLength), allocated,
                                  shared, logical, clamped, false))
        }
    }
}

extension FileScanner {
    /// Requested once, reused for every `getattrlistbulk` call.
    static var bulkAttributeList: attrlist {
        var a = attrlist()
        a.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        a.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
        // File attributes come back in bitmap order: LINKCOUNT (0x1), then
        // TOTALSIZE (0x2), then ALLOCSIZE (0x4).
        a.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT)
            | attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        return a
    }
}
