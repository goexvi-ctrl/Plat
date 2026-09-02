import Darwin
import Foundation
import PlatCore

// A/B harness: the 2004 traversal against the current one, on the same tree.
//
//   plat-bench <path> [--workers N] [--skip-legacy]

var path = FileManager.default.homeDirectoryForCurrentUser.path
var workerOverride: Int? = nil
var runLegacy = true
var renderTo: String? = nil
var renderLayout: TreemapLayout = .squarified
var renderSize = CGSize(width: 1200, height: 800)
var renderDepth = 0

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--workers": i += 1; workerOverride = Int(args[i])
    case "--skip-legacy": runLegacy = false
    case "--render": i += 1; renderTo = args[i]
    case "--layout": i += 1; renderLayout = TreemapLayout(rawValue: args[i]) ?? .squarified
    case "--depth": i += 1; renderDepth = Int(args[i]) ?? 0
    case "--size":
        i += 1
        let parts = args[i].split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 { renderSize = CGSize(width: parts[0], height: parts[1]) }
    default: path = args[i]
    }
    i += 1
}

func seconds(_ body: () throws -> Void) rethrows -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9
}

// Render mode: scan, lay out and paint straight to a PNG. No window server
// needed, which makes the drawing path checkable from a terminal.
if let out = renderTo {
    let tree = try FileScanner.scan(path: path)
    var options = TreemapOptions(layout: renderLayout)
    options.minVisibleArea = 6
    if renderDepth > 0 { options.maxDepth = renderDepth }
    guard let png = TreemapRenderer.renderToPNG(tree: tree, root: 0, size: renderSize,
                                                options: options) else {
        fputs("render failed\n", stderr); exit(1)
    }
    try png.write(to: URL(fileURLWithPath: out))
    let map = Treemap.build(tree: tree, root: 0,
                            bounds: CGRect(origin: .zero, size: renderSize), options: options)
    print("Wrote \(out): \(map.boxes.count) boxes, \(tree.nodes.count) nodes, "
          + "\(ByteFormat.string(tree.totalSize))")
    exit(0)
}

print("Scanning \(path)\n")

if runLegacy {
    var files = 0, dirs = 0
    var bytes: Int64 = 0
    let t = seconds { LegacyScanner.walk(path, files: &files, dirs: &dirs, bytes: &bytes) }
    print(String(format: "2004 walk (opendir + getattrlist per file, 1 thread)"))
    print(String(format: "  %8.3f s   %d files, %d dirs, %@",
                 t, files, dirs, ByteFormat.string(bytes)))
    print("")
}

for w in (workerOverride.map { [$0] } ?? [1, 2, 4, 8]) {
    var tree = FileTree.empty
    let t = try seconds {
        tree = try FileScanner.scan(path: path, options: ScanOptions(workers: w))
    }
    print(String(format: "getattrlistbulk, %2d thread(s)", w))
    print(String(format: "  %8.3f s   %d files, %d dirs, %@ on disk (%@ logical)",
                 t, tree.stats.files, tree.stats.directories,
                 ByteFormat.string(tree.stats.allocatedBytes),
                 ByteFormat.string(tree.stats.totalBytes)))
}

// Layout timing on the tree we just built.
var tree = try FileScanner.scan(path: path, options: ScanOptions())
let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
for layout in TreemapLayout.allCases {
    var map = Treemap.empty
    let t = seconds {
        map = Treemap.build(tree: tree, root: 0, bounds: bounds,
                            options: TreemapOptions(layout: layout))
    }
    print(String(format: "\nlayout %@ at 1600x1000", layout.displayName))
    print(String(format: "  %8.4f s   %d visible boxes (of %d nodes)",
                 t, map.boxes.count, tree.nodes.count))
}
