import Darwin
import Foundation

/// Stops a whole-disk scan counting the Data volume twice.
///
/// macOS presents the System and Data volumes of a volume group as a single
/// filesystem: they share one `dev_t`, and firmlinks connect them, so `/Users`
/// and `/System/Volumes/Data/Users` are the *same directory* -- same inode --
/// reached by two paths.  A scan of `/` therefore meets everything on the Data
/// volume twice, once through each.  On this machine that inflated a scan of
/// `/` from 7.9M entries to 10.5M, and from 1.81 TB to 1.93 TB.
///
/// The device check cannot catch it, because there is no device boundary to
/// see.  Tracking every directory's inode would catch it, but costs tens of
/// megabytes to fire about eighteen times.
///
/// Instead the system's own table at `/usr/share/firmlinks` says exactly which
/// paths are doubled.  We keep the familiar path (`/Users`) and shadow the
/// duplicate (`/System/Volumes/Data/Users`).
///
/// Note that the table does *not* cover the whole Data volume --
/// `.Spotlight-V100`, `.DocumentRevisions-V100`, `MobileSoftwareUpdate` and
/// others have no firmlink pointing at them -- so `/System/Volumes/Data` itself
/// is still descended.  Skipping it wholesale would silently lose real space.
public struct FirmlinkShadow: Sendable {
    /// Absolute paths that duplicate a firmlink and should not be descended.
    private var shadowed: [[UInt8]] = []
    /// Lengths present in `shadowed`, so the common case costs one lookup.
    private var lengths: Set<Int> = []

    public var isEmpty: Bool { shadowed.isEmpty }
    public var paths: [String] { shadowed.map { String(decoding: $0, as: UTF8.self) } }

    public init() {}

    /// Build the shadow list for a scan rooted at `root`.
    public init(root: String, tablePath: String = "/usr/share/firmlinks") {
        guard let table = try? String(contentsOfFile: tablePath, encoding: .utf8) else { return }

        // Each line is "<path on the system volume>\t<path within the data volume>".
        var links: [(source: String, target: String)] = []
        for line in table.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("/"), !parts[1].isEmpty else { continue }
            links.append((parts[0], parts[1]))
        }
        guard !links.isEmpty else { return }

        // Find where the data volume is mounted by asking the system for a
        // firmlink's real path and removing the part we already know.
        guard let dataRoot = Self.dataVolumeRoot(using: links) else { return }

        // Only shadow when the scan can actually reach both paths.  Scanning
        // /System/Volumes/Data directly must see all of it.
        guard Self.contains(root, dataRoot), !Self.contains(dataRoot, root) else { return }

        for link in links {
            shadowed.append(Array((dataRoot + "/" + link.target).utf8))
        }
        lengths = Set(shadowed.map(\.count))
    }

    /// Is `path` a duplicate we have already reached by its familiar name?
    /// `path` is the NUL-terminated form the scanner carries.
    public func shadows(_ path: [CChar]) -> Bool {
        guard !shadowed.isEmpty else { return false }
        let n = path.count - 1                    // drop the terminator
        guard n > 0, lengths.contains(n) else { return false }
        for candidate in shadowed where candidate.count == n {
            var same = true
            for i in 0 ..< n where candidate[i] != UInt8(bitPattern: path[i]) {
                same = false
                break
            }
            if same { return true }
        }
        return false
    }

    /// `/System/Volumes/Data`, derived rather than hardcoded: ask for a
    /// firmlink's path with firmlinks resolved, then strip the part we know.
    private static func dataVolumeRoot(using links: [(source: String, target: String)]) -> String? {
        for link in links {
            guard let resolved = noFirmlinkPath(link.source), resolved != link.source else { continue }
            let suffix = "/" + link.target
            guard resolved.hasSuffix(suffix) else { continue }
            let root = String(resolved.dropLast(suffix.count))
            if !root.isEmpty { return root }
        }
        return nil
    }

    /// ATTR_CMNEXT_NOFIRMLINKPATH: the path with firmlinks resolved away.
    static func noFirmlinkPath(_ path: String) -> String? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_NOFIRMLINKPATH)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            getattrlist(path, &list, raw.baseAddress, raw.count,
                        UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED))
        }
        guard rc == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            let ref = raw.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size,
                                        as: attrreference_t.self)
            guard ref.attr_length > 1 else { return nil }
            let base = raw.baseAddress!
                .advanced(by: MemoryLayout<UInt32>.size + Int(ref.attr_dataoffset))
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Is `inner` at or below `outer`, comparing whole path components?
    static func contains(_ outer: String, _ inner: String) -> Bool {
        if outer == "/" { return true }
        if outer == inner { return true }
        return inner.hasPrefix(outer + "/")
    }
}
