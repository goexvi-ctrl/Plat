import Darwin
import Foundation

/// A faithful reimplementation of the 2004 `_tree()` walk, for comparison:
/// `opendir`/`readdir`, then a separate `getattrlist` for every entry, on one
/// thread.  Same attributes the original asked for (devid, finder info, access
/// mask, data length, resource length).
enum LegacyScanner {

    // `getattrlist` writes its result packed, with no alignment padding -- which
    // is why the 2004 header declared `Attrs_t` `__attribute__((__packed__))`.
    // Swift has no packed structs: declaring the equivalent Swift struct puts
    // `dataLength` at offset 48 instead of 44, and every size silently reads
    // back as garbage.  So decode from a raw buffer at explicit offsets.
    //
    //   0  u_int32_t   length
    //   4  dev_t       ATTR_CMN_DEVID
    //   8  32 bytes    ATTR_CMN_FNDRINFO
    //  40  u_int32_t   ATTR_CMN_ACCESSMASK
    //  44  off_t       ATTR_FILE_DATALENGTH
    //  52  off_t       ATTR_FILE_RSRCLENGTH
    private enum Offset {
        static let devid = 4
        static let dataLength = 44
        static let rsrcLength = 52
        static let bufferSize = 60
    }

    private static var attributeList: attrlist {
        var a = attrlist()
        a.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        a.commonattr = attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_FNDRINFO)
            | attrgroup_t(ATTR_CMN_ACCESSMASK)
        a.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH) | attrgroup_t(ATTR_FILE_RSRCLENGTH)
        return a
    }

    static func walk(_ root: String, files: inout Int, dirs: inout Int, bytes: inout Int64) {
        var rootDev: dev_t = 0
        var st = stat()
        if stat(root, &st) == 0 { rootDev = st.st_dev }
        var path = Array(root.utf8).map { CChar(bitPattern: $0) }
        while path.count > 1 && path.last == CChar(UInt8(ascii: "/")) { path.removeLast() }
        descend(&path, rootDev, &files, &dirs, &bytes)
    }

    private static func descend(_ path: inout [CChar], _ rootDev: dev_t,
                                _ files: inout Int, _ dirs: inout Int, _ bytes: inout Int64) {
        var terminated = path
        terminated.append(0)
        guard let dp = terminated.withUnsafeBufferPointer({ opendir($0.baseAddress!) }) else { return }
        dirs += 1

        let base = path.count
        var attrs = attributeList
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Offset.bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        while let entry = readdir(dp) {
            var nameBuf = entry.pointee.d_name
            let nameLength = Int(entry.pointee.d_namlen)
            let type = entry.pointee.d_type

            let skip: Bool = withUnsafeBytes(of: &nameBuf) { raw in
                let b = raw.bindMemory(to: UInt8.self)
                if nameLength == 1 && b[0] == UInt8(ascii: ".") { return true }
                if nameLength == 2 && b[0] == UInt8(ascii: ".") && b[1] == UInt8(ascii: ".") { return true }
                return false
            }
            if skip { continue }
            if type != DT_DIR && type != DT_REG { continue }

            path.removeLast(path.count - base)
            if !(base == 1 && path[0] == CChar(UInt8(ascii: "/"))) {
                path.append(CChar(UInt8(ascii: "/")))
            }
            withUnsafeBytes(of: &nameBuf) { raw in
                let b = raw.bindMemory(to: UInt8.self)
                for i in 0 ..< nameLength { path.append(CChar(bitPattern: b[i])) }
            }

            var probe = path
            probe.append(0)
            let ok = probe.withUnsafeBufferPointer { p in
                getattrlist(p.baseAddress!, &attrs, buffer,
                            Offset.bufferSize, UInt32(FSOPT_NOFOLLOW)) == 0
            }

            if type == DT_DIR {
                let devid = buffer.loadUnaligned(fromByteOffset: Offset.devid, as: dev_t.self)
                if ok && devid == rootDev {
                    descend(&path, rootDev, &files, &dirs, &bytes)
                }
            } else if ok {
                files += 1
                bytes += Int64(buffer.loadUnaligned(fromByteOffset: Offset.dataLength, as: off_t.self))
                bytes += Int64(buffer.loadUnaligned(fromByteOffset: Offset.rsrcLength, as: off_t.self))
            }
        }
        path.removeLast(path.count - base)
        closedir(dp)
    }
}
