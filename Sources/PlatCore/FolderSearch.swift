import Foundation

public struct FolderMatch: Sendable, Identifiable, Equatable {
    public var node: Int
    /// Path relative to the scan root, e.g. "src/Plat".
    public var relativePath: String
    public var size: Int64
    /// True when the query matched the folder's whole name, not just part of it.
    public var isExactName: Bool

    public var id: Int { node }
}

extension FileTree {

    /// Find folders whose name matches `query`.
    ///
    /// A query with no slash matches folder names; "src/Space" additionally
    /// requires an ancestor matching "src", so a path fragment narrows the
    /// search the way you would expect.  Matching is case-insensitive for
    /// ASCII and works directly on the stored name bytes -- building a String
    /// per node would mean a million allocations on every keystroke.
    public func findFolders(matching query: String, limit: Int = 200) -> [FolderMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // An absolute path inside the scanned tree is stripped down to a
        // relative one, so pasting a full path works.
        var text = trimmed
        if text.hasPrefix(rootPath) {
            text = String(text.dropFirst(rootPath.count))
        }
        let parts = text.split(separator: "/").map { fold(Array($0.utf8)) }
        guard let needle = parts.last, !needle.isEmpty else { return [] }
        let ancestorNeedles = parts.dropLast()

        var matches: [FolderMatch] = []
        names.withUnsafeBufferPointer { buf in
            for i in 0 ..< nodes.count where nodes[i].isDirectory {
                let node = nodes[i]
                let lo = Int(node.nameOffset)
                let hi = lo + Int(node.nameLength)
                guard hi > lo, Self.contains(buf, lo, hi, needle) else { continue }
                guard ancestorNeedles.isEmpty || matchesAncestors(i, ancestorNeedles, buf) else { continue }
                let exact = Int(node.nameLength) == needle.count
                matches.append(FolderMatch(node: i, relativePath: "",
                                           size: size(of: i), isExactName: exact))
            }
        }

        // Whole-name matches first, then biggest first: when you type
        // "node_modules" you almost always want the one using the most space.
        matches.sort {
            if $0.isExactName != $1.isExactName { return $0.isExactName }
            return $0.size > $1.size
        }
        if matches.count > limit { matches.removeSubrange(limit...) }
        // Paths are built only for the handful actually shown.
        return matches.map {
            var m = $0
            m.relativePath = relativePath(of: $0.node)
            return m
        }
    }

    /// Every earlier path component must match some ancestor, in order.
    private func matchesAncestors(_ index: Int, _ needles: ArraySlice<[UInt8]>,
                                  _ buf: UnsafeBufferPointer<UInt8>) -> Bool {
        var chain: [Int] = []
        var i = Int(nodes[index].parent)
        while i >= 0 {
            chain.append(i)
            i = Int(nodes[i].parent)
        }
        chain.reverse()               // root first

        var next = needles.startIndex
        for node in chain {
            guard next < needles.endIndex else { break }
            let lo = Int(nodes[node].nameOffset)
            let hi = lo + Int(nodes[node].nameLength)
            if hi > lo, Self.contains(buf, lo, hi, needles[next]) { next += 1 }
        }
        return next == needles.endIndex
    }

    /// Path relative to the scan root; "" for the root itself.
    public func relativePath(of index: Int) -> String {
        var parts: [String] = []
        var i = index
        while nodes[i].parent >= 0 {
            parts.append(name(of: i))
            i = Int(nodes[i].parent)
        }
        return parts.reversed().joined(separator: "/")
    }

    /// Resolve an exact path, absolute or relative to the scan root.
    public func node(atPath path: String) -> Int? {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(rootPath) { text = String(text.dropFirst(rootPath.count)) }
        let wanted = text.split(separator: "/").map(String.init)
        var current = root
        outer: for component in wanted {
            for child in children(of: current) where name(of: child) == component {
                current = child
                continue outer
            }
            return nil
        }
        return current
    }

    private func fold(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
    }

    /// Case-insensitive (ASCII) substring test over the raw name bytes.
    private static func contains(_ buf: UnsafeBufferPointer<UInt8>,
                                 _ lo: Int, _ hi: Int, _ needle: [UInt8]) -> Bool {
        let n = needle.count
        let span = hi - lo
        guard n > 0, span >= n else { return false }
        let first = needle[0]
        var start = lo
        let last = hi - n
        while start <= last {
            var b = buf[start]
            if b >= 65 && b <= 90 { b += 32 }
            if b == first {
                var k = 1
                while k < n {
                    var c = buf[start + k]
                    if c >= 65 && c <= 90 { c += 32 }
                    if c != needle[k] { break }
                    k += 1
                }
                if k == n { return true }
            }
            start += 1
        }
        return false
    }
}

/// How much space each file extension accounts for.
public struct ExtensionUsage: Sendable, Identifiable, Equatable {
    public var ext: String
    public var bytes: Int64
    public var files: Int
    public var id: String { ext }
}

extension FileTree {
    /// The extensions using the most space in this scan, biggest first.
    ///
    /// Used to seed the colour settings: guessing which extensions matter is
    /// the user's problem, and the scan already knows the answer.  One pass
    /// over the nodes, so it is a few hundred milliseconds on a very large
    /// scan and is only run when the dialog asks for it.
    public func extensionUsage(limit: Int = 40) -> [ExtensionUsage] {
        var totals: [String: (bytes: Int64, files: Int)] = [:]
        totals.reserveCapacity(256)

        names.withUnsafeBufferPointer { buf in
            for i in 0 ..< nodes.count {
                let node = nodes[i]
                guard !node.isDirectory else { continue }
                let size = size(of: i)
                guard size > 0 else { continue }
                let lo = Int(node.nameOffset)
                let hi = lo + Int(node.nameLength)
                var dot = -1
                var j = hi - 1
                while j > lo {
                    if buf[j] == UInt8(ascii: ".") { dot = j; break }
                    j -= 1
                }
                guard dot >= 0, dot + 1 < hi, hi - dot - 1 <= 16 else { continue }
                var bytes = [UInt8]()
                bytes.reserveCapacity(hi - dot - 1)
                for k in (dot + 1) ..< hi {
                    let b = buf[k]
                    bytes.append(b >= 65 && b <= 90 ? b + 32 : b)
                }
                let key = String(decoding: bytes, as: UTF8.self)
                totals[key, default: (0, 0)].bytes += size
                totals[key, default: (0, 0)].files += 1
            }
        }

        return totals
            .map { ExtensionUsage(ext: $0.key, bytes: $0.value.bytes, files: $0.value.files) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }
}
