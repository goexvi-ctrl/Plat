import AppKit
import PlatCore
import SwiftUI
import UniformTypeIdentifiers

/// What the user clicked, and where, so the popover can point at it.
struct Inspection: Identifiable, Equatable {
    let id = UUID()
    var node: Int
    var point: CGPoint
    /// Worked out once, when the click happens.  Assessing costs an `lstat`
    /// and a walk of every running application, which is not something to
    /// repeat on each pass of the view body.
    var risk: DeleteRisk = .normal

    static func == (a: Inspection, b: Inspection) -> Bool { a.id == b.id }
}

/// Details of one file or folder, at a size that can be read across the room.
///
/// The 2004 build tried to do this with tooltips; that code never worked and was
/// left `#if 0`'d out in `draw.m`.
struct InfoPanel: View {
    let tree: FileTree
    let node: Int
    /// Size of the figures; everything else here is relative to it.
    var baseFontSize: Double = AppearanceSettings.defaultUIFontSize
    /// How risky deleting this would be.  Computed by the model, which knows
    /// which applications are running.
    var risk: DeleteRisk = .normal
    var onZoom: (Int) -> Void
    var onDelete: (Int) -> Void

    private var nameSize: CGFloat { CGFloat(baseFontSize + 2) }
    private var iconSize: CGFloat { CGFloat(baseFontSize + 4) }
    private var rowSize: CGFloat { CGFloat(baseFontSize) }
    private var buttonSize: CGFloat { CGFloat(baseFontSize - 1) }
    private var smallSize: CGFloat { CGFloat(baseFontSize - 3) }

    @State private var copied: String?
    /// What file(1) makes of the contents.  Fetched when the panel opens, since
    /// it runs a process, and left out entirely when it says nothing useful.
    @State private var contents: String?

    private var entry: FileTree.Node { tree.nodes[node] }
    /// This name is being charged only a share of the file's blocks.
    private var isSharedAway: Bool {
        tree.isHardLinked(node) && tree.metric == .onDisk && tree.splitHardLinks
    }
    private var name: String { tree.name(of: node) }
    private var path: String { tree.path(of: node) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            details
            // A capacity block is not a file: it has no path, so nothing to
            // open, reveal or preview.
            if !entry.isSynthetic, entry.isDirectory || !path.isEmpty {
                Divider()
                actions
            }
        }
        .padding(20)
        .frame(width: 420)
        .task(id: node) { await loadContents() }
    }

    /// `file` reads the head of the file, which is quick on a local disk and
    /// arbitrarily slow on a stalled network mount -- so never on the main
    /// thread, and never for a capacity block or a file that has gone.
    private func loadContents() async {
        contents = nil
        guard !entry.isSynthetic, !tree.isGone(node), !entry.isDirectory else { return }
        let target = path
        let described = await Task.detached(priority: .userInitiated) {
            FileDescription.of(path: target)
        }.value
        // The panel may have moved on to another box while that ran.
        guard target == path else { return }
        contents = described
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)

                // Click the name to copy it, as requested.
                CopyButton(text: name, copied: $copied, label: "name") {
                    Text(name)
                        .font(.system(size: nameSize, weight: .semibold))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if entry.isSynthetic {
                Text(syntheticExplanation)
                    .font(.system(size: smallSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            CopyButton(text: path, copied: $copied, label: "path") {
                Text(path)
                    .font(.system(size: smallSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
            }

            }
            if !entry.isSynthetic {
            Text(copied.map { "Copied \($0) to the clipboard" } ?? "Click the name or path to copy it")
                .font(.system(size: smallSize))
                .foregroundStyle(copied == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .animation(.easeInOut(duration: 0.15), value: copied)
            }
        }
    }

    /// Capacity blocks need explaining; a folder does not.
    private var syntheticExplanation: String {
        switch tree.synthetic(node) {
        case .freeSpace:
            return "Unused space on this volume."
        case .notScanned:
            return "Space the volume reports as in use that this scan did not "
                 + "see: other volumes sharing the same container, APFS "
                 + "snapshots, folders it was not permitted to read \u{2014} "
                 + "including a volume's own .Trashes, which is not listable "
                 + "\u{2014} and purgeable space.  macOS reports no size per "
                 + "snapshot, so these cannot be separated."
        case nil:
            return ""
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Both sizes, always, with the one driving the map emphasised.  For
            // a sparse file these differ enormously, and seeing that side by
            // side is the point.
            // With splitting on, a linked file's share -- not its full block
            // count -- is what drives the map, so that is the figure to stress.
            row("Size on disk", ByteFormat.string(entry.allocatedSize),
                strong: tree.metric == .onDisk && !isSharedAway)
            row("Logical size", ByteFormat.string(entry.logicalSize),
                strong: tree.metric == .logical)
            if entry.logicalSize > entry.allocatedSize * 2 && entry.allocatedSize >= 0 {
                row("", "sparse or compressed \u{2014} it frees only "
                    + ByteFormat.string(entry.allocatedSize))
            }
            if tree.isHardLinked(node) {
                row("Hard links", "\(entry.linkCount) names share these blocks",
                    strong: true)
                row("", "deleting this name frees nothing; the space goes only "
                    + "when the last name does")
                if isSharedAway {
                    row("Counted as", ByteFormat.string(entry.allocatedShared)
                        + " (an equal share of "
                        + ByteFormat.string(entry.allocatedSize) + ")",
                        strong: true)
                }
            }
            row("Bytes", tree.size(of: node).formatted(.number.grouping(.automatic)))
            row("Kind", kind)
            if let contents {
                row("Contents", contents)
            }
            if let package = tree.packageKind(of: node) {
                row("Shown as", "one item \u{2014} macOS treats this "
                    + "\(package.noun) as a single file",
                    strong: true)
                row("", "Zoom In to look inside; deleting anything in there "
                    + "separately would break it")
            }
            if entry.isDirectory {
                let counts = tree.subtreeCounts(of: node)
                row("Contains", "\(ByteFormat.count(Int(entry.childCount))) items here, "
                    + "\(ByteFormat.count(counts.files + counts.folders)) in all")
            }
            // Keeping the parent's name out of the label column stops long
            // folder names from wrapping it; the name is already in the path.
            if entry.parent >= 0 {
                row("Share of parent", share(of: tree.size(of: Int(entry.parent))))
            }
            // When the parent *is* the root these two are the same number.
            if node != tree.root && Int(entry.parent) != tree.root {
                row("Share of scan", share(of: tree.totalSize))
            }
        }
    }

    private func row(_ label: String, _ value: String, strong: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: rowSize))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .font(.system(size: rowSize, weight: strong ? .bold : .medium))
                .foregroundStyle(strong ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func share(of total: Int64) -> String {
        guard total > 0 else { return "\u{2014}" }
        let pct = Double(tree.size(of: node)) / Double(total) * 100
        return pct >= 10 ? String(format: "%.0f%%", pct)
             : pct >= 1  ? String(format: "%.1f%%", pct)
                         : String(format: "%.2f%%", pct)
    }

    private var kind: String {
        if let package = tree.packageKind(of: node) {
            let ext = (name as NSString).pathExtension
            if let described = UTType(filenameExtension: ext, conformingTo: .directory)?
                .localizedDescription {
                return described
            }
            return package == .code ? "Application bundle" : "Document package"
        }
        if entry.isDirectory { return "Folder" }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "File" }
        if let type = UTType(filenameExtension: ext), let described = type.localizedDescription {
            return described
        }
        return "\(ext.uppercased()) file"
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    QuickLook.shared.show(path)
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .help("Preview without opening an application")

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .help(entry.isDirectory
                      ? "Open this folder in the Finder"
                      : "Open in the application that handles this file")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Reveal", systemImage: "magnifyingglass")
                }
                .help("Show it in the Finder")

                Spacer()
            }
            // Only the filesystem actions depend on the file still being there;
            // zooming works on the scan already in memory.
            .disabled(!exists)

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    onDelete(node)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(!exists || risk == .blocked)
                .help(risk == .blocked
                      ? "The system will not allow this item to be deleted"
                      : "Move this item to the Trash")

                // The verdict, next to the button that acts on it.  A folder of
                // caches and a folder inside an application look identical on
                // the map; this is where the difference shows up.
                if exists, risk != .normal {
                    Label(risk.label, systemImage: riskSymbol)
                        .font(.system(size: smallSize, weight: .medium))
                        .foregroundStyle(riskColor)
                }
                Spacer()
            }
            if entry.childCount > 0 {
                Button {
                    onZoom(node)
                } label: {
                    Label("Zoom In", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
            if !exists {
                // A scan is a snapshot; by now the file may be gone, and the
                // buttons above would silently do nothing.
                Label("No longer on disk", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.system(size: smallSize))
            }
        }
        .font(.system(size: buttonSize))
    }

    private var exists: Bool { !tree.isGone(node) && QuickLook.canPreview(path) }

    private var riskSymbol: String {
        switch risk {
        case .safe:    return "checkmark.circle"
        case .normal:  return "trash"
        case .caution: return "exclamationmark.circle"
        case .danger:  return "exclamationmark.triangle.fill"
        case .blocked: return "nosign"
        }
    }

    private var riskColor: Color {
        switch risk {
        case .safe:    return .green
        case .normal:  return .secondary
        case .caution: return .orange
        case .danger:  return .red
        case .blocked: return .secondary
        }
    }

}

/// A borderless button that copies `text` and reports what it copied.
private struct CopyButton<Label: View>: View {
    let text: String
    @Binding var copied: String?
    let label: String
    @ViewBuilder var content: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: copy) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(hovering ? 0.15 : 0))
                        .padding(-4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to copy the \(label)")
    }

    private func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        copied = label
    }
}
