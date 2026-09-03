import Darwin
import Foundation

/// Capacity figures for the volume a path lives on.
///
/// On APFS these are container-wide: every volume in a container draws from one
/// pool of free blocks, which is why `/` and `/System/Volumes/Data` report the
/// same free space.  So "used" here covers sibling volumes (Preboot, Recovery,
/// VM) as well as the one being scanned.
public struct VolumeInfo: Sendable, Equatable {
    /// Where the volume is mounted, as the kernel spells it.
    public var mountPoint: String
    public var totalBytes: Int64
    /// What a user can actually write, which is what "free" should mean to them.
    public var freeBytes: Int64
    public var usedBytes: Int64

    public init(mountPoint: String, totalBytes: Int64, freeBytes: Int64, usedBytes: Int64) {
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
    }

    public static func of(path: String) -> VolumeInfo? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let block = Int64(s.f_bsize)
        let total = Int64(s.f_blocks) * block
        // f_bfree counts blocks the filesystem considers free; f_bavail excludes
        // what is reserved from unprivileged writers.  A person cares about the
        // latter, so that is "free" and everything else is "used".
        let free = Int64(s.f_bavail) * block
        let mount = withUnsafeBytes(of: s.f_mntonname) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return VolumeInfo(mountPoint: mount, totalBytes: total,
                          freeBytes: free, usedBytes: max(0, total - free))
    }

    /// True when `path` is the volume's own mount point, rather than a folder
    /// somewhere inside it.  Capacity blocks only make sense for a whole volume.
    public static func isMountPoint(_ path: String) -> Bool {
        guard let info = of(path: path) else { return false }
        return info.mountPoint == path
    }
}
