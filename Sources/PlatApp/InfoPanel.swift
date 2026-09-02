import AppKit
import PlatCore
import SwiftUI
import UniformTypeIdentifiers

/// What the user clicked, and where, so the popover can point at it.
struct Inspection: Identifiable, Equatable {
    let id = UUID()
    var node: Int
    var point: CGPoint

    static func == (a: Inspection, b: Inspection) -> Bool { a.id == b.id }
}

/// Details of one file or folder, at a size that can be read across the room.
///
/// The 2004 build tried to do this with tooltips; that code never worked and was
/// left `#if 0`'d out in `draw.m`.
struct InfoPanel: View {
    let tree: FileTree
    let node: Int
    var onZoom: (Int) -> Void

    @State private var copied: String?

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
            if entry.isDirectory || !path.isEmpty { Divider(); actions }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)

                // Click the name to copy it, as requested.
                CopyButton(text: name, copied: $copied, label: "name") {
                    Text(name)
                        .font(.system(size: 22, weight: .semibold))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            CopyButton(text: path, copied: $copied, label: "path") {
                Text(path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
            }

            Text(copied.map { "Copied \($0) to the clipboard" } ?? "Click the name or path to copy it")
                .font(.system(size: 11))
                .foregroundStyle(copied == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .animation(.easeInOut(duration: 0.15), value: copied)
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
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .font(.system(size: 14, weight: strong ? .bold : .medium))
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
        HStack(spacing: 10) {
            if entry.childCount > 0 {
                Button {
                    onZoom(node)
                } label: {
                    Label("Zoom In", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass")
            }
            Spacer()
        }
        .font(.system(size: 13))
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
