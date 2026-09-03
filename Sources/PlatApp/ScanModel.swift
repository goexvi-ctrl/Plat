import AppKit
import Foundation
import PlatCore
import SwiftUI

/// A cancellation flag that the scan threads can poll without a lock.
final class CancelFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@Observable
@MainActor
final class ScanModel {

    enum Phase: Equatable {
        case empty
        case scanning(ScanStats)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .empty
    private(set) var tree = FileTree.empty
    /// True when the view is currently inside a bundle, which only happens
    /// because the user asked to look inside one.
    var isInsidePackage: Bool {
        !tree.isEmpty && tree.ancestry(of: focus).contains { tree.isPackage($0) }
    }

    /// The subtree currently filling the window.
    private(set) var focus = 0
    private(set) var scannedPath: String?

    var layout: TreemapLayout = .squarified {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey) }
    }
    var showLabels = true {
        didSet { UserDefaults.standard.set(showLabels, forKey: Self.labelsKey) }
    }
    /// How many levels of nesting to draw; 0 means every level.
    var depthLimit = 0 {
        didSet { UserDefaults.standard.set(depthLimit, forKey: Self.depthKey) }
    }
    /// Draw applications and document libraries as single boxes.  On by
    /// default: an application is one thing to install, one thing to delete,
    /// and one thing to reason about, so it should be one box.
    var collapsePackages = true {
        didSet { UserDefaults.standard.set(collapsePackages, forKey: Self.packagesKey) }
    }
    /// Divide a hard-linked file's disk usage among its names.  On by default:
    /// deleting one of several names frees nothing, so charging the full size to
    /// each name overstates what a cleanup would actually recover.
    var splitHardLinks = true {
        didSet {
            UserDefaults.standard.set(splitHardLinks, forKey: Self.splitKey)
            tree.splitHardLinks = splitHardLinks
        }
    }
    /// Which size to draw.  Both were measured during the scan, so switching is
    /// instant -- no rescan.
    var metric: SizeMetric = .onDisk {
        didSet {
            UserDefaults.standard.set(metric.rawValue, forKey: Self.metricKey)
            tree.metric = metric
        }
    }

    /// Ask before every delete.  On by default and deliberately so: the map
    /// makes it easy to click a 40 GB folder by accident, and the confirmation
    /// is the only place the safety assessment is ever shown.
    var confirmBeforeDelete = true {
        didSet { UserDefaults.standard.set(confirmBeforeDelete, forKey: Self.confirmKey) }
    }

    /// The delete awaiting confirmation, which drives the sheet.
    var pendingDelete: DeleteRequest?
    /// The last completed delete, offered for undo until another one replaces it.
    private(set) var lastDelete: CompletedDelete?
    /// A delete or undo that failed, shown as an alert.
    var deleteError: String?

    private var cancelFlag: CancelFlag?

    private static let layoutKey = "TreemapLayout"
    private static let labelsKey = "ShowLabels"
    private static let metricKey = "SizeMetric"
    private static let depthKey = "DepthLimit"
    private static let splitKey = "SplitHardLinks"
    private static let confirmKey = "ConfirmBeforeDelete"
    private static let packagesKey = "CollapsePackages"
    /// Beyond this, nesting is invisible anyway: each level costs a label strip
    /// plus padding, so a tall window runs out of room around 20.
    static let maxDepthLimit = 24

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.layoutKey),
           let saved = TreemapLayout(rawValue: raw) {
            layout = saved
        }
        if UserDefaults.standard.object(forKey: Self.labelsKey) != nil {
            showLabels = UserDefaults.standard.bool(forKey: Self.labelsKey)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.metricKey),
           let saved = SizeMetric(rawValue: raw) {
            metric = saved
        }
        if UserDefaults.standard.object(forKey: Self.depthKey) != nil {
            depthLimit = UserDefaults.standard.integer(forKey: Self.depthKey)
        }
        if UserDefaults.standard.object(forKey: Self.splitKey) != nil {
            splitHardLinks = UserDefaults.standard.bool(forKey: Self.splitKey)
        }
        if UserDefaults.standard.object(forKey: Self.packagesKey) != nil {
            collapsePackages = UserDefaults.standard.bool(forKey: Self.packagesKey)
        }
        if UserDefaults.standard.object(forKey: Self.confirmKey) != nil {
            confirmBeforeDelete = UserDefaults.standard.bool(forKey: Self.confirmKey)
        }
        // `Plat /some/path` scans that folder on launch.
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
           FileManager.default.fileExists(atPath: path) {
            scan(path: path)
        }
    }

    var options: TreemapOptions {
        var o = TreemapOptions(layout: layout)
        o.labelHeight = showLabels ? 13 : 0
        o.padding = showLabels ? 3 : 1
        o.maxDepth = depthLimit == 0 ? 64 : min(depthLimit, Self.maxDepthLimit)
        o.collapsePackages = collapsePackages
        return o
    }

    var isScanning: Bool { if case .scanning = phase { return true }; return false }
    var isReady: Bool { phase == .ready }

    // MARK: Navigation

    func focus(on node: Int) {
        guard node >= 0, node < tree.nodes.count else { return }
        // A file is never a destination; an empty folder is (it just draws blank).
        guard tree.nodes[node].isDirectory || tree.nodes[node].childCount > 0 else { return }
        focus = node
    }

    func goUp() {
        guard focus != tree.root else { return }
        let parent = tree.nodes[focus].parent
        focus = parent >= 0 ? Int(parent) : tree.root
    }

    func goToRoot() { focus = tree.root }

    var canGoUp: Bool { !tree.isEmpty && focus != tree.root }

    var breadcrumb: [Int] { tree.isEmpty ? [] : tree.ancestry(of: focus) }

    /// The window title.  Empty once a scan is showing: the toolbar's path
    /// widget already names the folder, and repeating it in the title bar just
    /// prints the same word twice.
    var windowTitle: String { isReady ? "" : "Plat" }

    // MARK: Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to measure"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            scan(path: url.path)
        }
    }

    func rescan() {
        if let path = scannedPath { scan(path: path) }
    }

    func cancel() {
        cancelFlag?.set()
    }

    func scan(path: String) {
        cancelFlag?.set()
        let flag = CancelFlag()
        cancelFlag = flag
        phase = .scanning(ScanStats())
        scannedPath = path

        // The scan blocks in syscalls across several threads of its own, so it
        // must not run on the Swift concurrency pool.  `ScanModel` is
        // `@MainActor`, and so implicitly `Sendable`, which lets the worker
        // hand results straight back without any shared global state.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result: Result<FileTree, Error>
            do {
                result = .success(try FileScanner.scan(
                    path: path,
                    isCancelled: { flag.isSet },
                    progress: { stats in
                        Task { @MainActor in self.report(stats, from: flag) }
                    }))
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in self.finish(result, from: flag) }
        }
    }

    /// Ignore anything arriving from a scan the user has already replaced.
    private func report(_ stats: ScanStats, from flag: CancelFlag) {
        guard cancelFlag === flag else { return }
        phase = .scanning(stats)
    }

    private func finish(_ result: Result<FileTree, Error>, from flag: CancelFlag) {
        guard cancelFlag === flag else { return }
        switch result {
        case .success(var scanned):
            scanned.metric = metric
            scanned.splitHardLinks = splitHardLinks
            tree = scanned
            focus = scanned.root
            phase = .ready
        case .failure(let error):
            if case ScanError.cancelled = error {
                phase = tree.isEmpty ? .empty : .ready
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Deleting

    /// One item the user has asked to delete, with the verdict on how risky it
    /// is.  Built when the delete is requested, not when the sheet draws, so
    /// the sheet renders a decision rather than making one.
    struct DeleteRequest: Identifiable {
        let id = UUID()
        var node: Int
        var name: String
        var path: String
        var isDirectory: Bool
        var size: Int64
        var files: Int
        var folders: Int
        var assessment: DeleteAssessment
    }

    struct CompletedDelete {
        var removal: FileTree.Removal
        var name: String
        /// Where it landed in the Trash.  Nil if macOS did not say, in which
        /// case Plat cannot offer to put it back itself.
        var trashURL: URL?
    }

    var canDelete: Bool { isReady }

    /// Assess a node without acting on it, for the info panel's badge.
    func assessment(for node: Int) -> DeleteAssessment {
        DeleteSafety.assess(tree: tree, node: node,
                            runningApplicationPaths: Self.runningApplicationPaths())
    }

    /// Step one of a delete: work out what it would cost and either ask or,
    /// when the user has turned confirmations off and the item is unremarkable,
    /// go ahead.
    func requestDelete(node: Int) {
        guard isReady, node > 0, node < tree.nodes.count else { return }
        let entry = tree.nodes[node]
        guard !entry.isSynthetic, !tree.isGone(node) else { return }

        let verdict = assessment(for: node)
        let counts = tree.subtreeCounts(of: node)
        let request = DeleteRequest(node: node,
                                    name: tree.name(of: node),
                                    path: tree.path(of: node),
                                    isDirectory: entry.isDirectory,
                                    size: tree.size(of: node),
                                    files: counts.files,
                                    folders: counts.folders,
                                    assessment: verdict)

        if verdict.risk == .blocked {
            // Nothing to confirm -- the delete cannot happen.  Say why.
            pendingDelete = request
            return
        }
        if confirmBeforeDelete || verdict.risk.alwaysConfirm {
            pendingDelete = request
        } else {
            perform(request)
        }
    }

    func cancelDelete() { pendingDelete = nil }

    /// Step two: the user said yes.
    func confirmDelete() {
        guard let request = pendingDelete else { return }
        pendingDelete = nil
        perform(request)
    }

    private func perform(_ request: DeleteRequest) {
        do {
            let trashed = try Trash.recycle(URL(fileURLWithPath: request.path))
            // The tree changes only once the file has actually moved, so a
            // refused delete never leaves the map lying about the disk.
            guard let removal = tree.remove(request.node) else { return }
            lastDelete = CompletedDelete(removal: removal,
                                         name: request.name,
                                         trashURL: trashed)
            // The free block was credited by inference; correct it against what
            // the volume really reports.  This is what makes a hard-linked
            // delete honest -- the blocks do not come back, and the difference
            // lands in "Not scanned" where it belongs.
            tree.refreshVolumeAccounting()
            retreatFromDeleted()
        } catch {
            deleteError = "Could not move \(request.name) to the Trash.\n"
                        + error.localizedDescription
        }
    }

    // MARK: Dragging out

    /// Whether an item may be dragged out of Plat as a move rather than only a
    /// copy.
    ///
    /// A drag offers nowhere to put a warning: by the time the drop lands the
    /// file has already gone.  So the same assessment that gates a delete gates
    /// this, and anything it calls risky is offered for copying only -- which
    /// the drag badge shows plainly.  Dragging one file out of an application
    /// bundle breaks the application just as surely as deleting it would.
    func allowsMove(_ node: Int) -> Bool {
        guard isReady, node > 0, node < tree.nodes.count else { return false }
        let entry = tree.nodes[node]
        guard !entry.isSynthetic, !tree.isGone(node) else { return false }
        return assessment(for: node).risk < .danger
    }

    /// A drag has finished.  Whether it was a move is decided by looking at the
    /// disk, not by the operation the drop target reported: a target may move a
    /// file without saying so, and the only question that matters is whether
    /// the file is still where the scan left it.
    func noteDragEnded(node: Int) {
        guard isReady, node > 0, node < tree.nodes.count, !tree.isGone(node) else { return }
        let path = tree.path(of: node)
        guard !FileManager.default.fileExists(atPath: path) else { return }

        tree.remove(node)
        // A move to another folder on the same volume frees nothing, and Plat
        // is never told where the file went -- so ask the filesystem what
        // actually changed rather than crediting the free block by hand.
        tree.refreshVolumeAccounting()
        retreatFromDeleted()
        // Not offered for undo: Plat does not know where the file was put, so
        // it has nothing to put back.
        lastDelete = nil
    }

    var canUndoDelete: Bool { lastDelete?.trashURL != nil }

    var undoDeleteTitle: String {
        lastDelete.map { "Undo Delete of \($0.name)" } ?? "Undo Delete"
    }

    /// Put the last deleted item back, both on disk and in the tree.
    func undoDelete() {
        guard let last = lastDelete, let trashed = last.trashURL else { return }
        do {
            try Trash.putBack(from: trashed, to: URL(fileURLWithPath: last.removal.path))
            tree.restore(last.removal)
            tree.refreshVolumeAccounting()
            lastDelete = nil
        } catch {
            deleteError = "Could not put \(last.name) back.\n"
                        + error.localizedDescription
        }
    }

    /// If the view was inside the folder that just went away, climb to the
    /// nearest ancestor that is still there.
    private func retreatFromDeleted() {
        guard tree.isGone(focus) else { return }
        var i = focus
        while i > 0, tree.isGone(i) { i = Int(tree.nodes[i].parent) }
        focus = max(i, tree.root)
    }

    /// Bundle paths of everything running right now.  Cheap, and it turns "this
    /// is part of an app" into "this is part of an app you are using".
    private static func runningApplicationPaths() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }
    }
}
