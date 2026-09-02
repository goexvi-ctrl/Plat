import PlatCore
import SwiftUI

/// Type a folder name to jump straight to it in an already-scanned tree.
///
/// Nothing here touches the disk: the scan is already in memory, so this is a
/// search over the node array, not a rescan.
struct GoToFolderView: View {
    let tree: FileTree
    var onGo: (Int) -> Void

    init(tree: FileTree, initialQuery: String = "", onGo: @escaping (Int) -> Void) {
        self.tree = tree
        self.onGo = onGo
        _query = State(initialValue: initialQuery)
    }

    @State private var query: String
    /// Held rather than recomputed: `body` reads the results from three places,
    /// and searching a million nodes three times per keystroke is waste.
    @State private var found: [FolderMatch] = []
    @State private var selection: Int?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private func refresh() {
        found = tree.findFolders(matching: query, limit: 200)
        selection = found.first?.node
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 620, height: 420)
        .onAppear { fieldFocused = true; refresh() }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Folder name, or a path like src/Plat", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($fieldFocused)
                .onSubmit(go)
                .onChange(of: query) { refresh() }
                .onMoveCommand { direction in
                    switch direction {
                    case .down: moveSelection(by: 1)
                    case .up:   moveSelection(by: -1)
                    default:    break
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var results: some View {
        if query.isEmpty {
            hint("Start typing to find a folder in \(tree.rootPath)")
        } else if found.isEmpty {
            hint("No folder matching \u{201c}\(query)\u{201d}")
        } else {
            List(found, selection: $selection) { match in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tree.name(of: match.node))
                            .font(.system(size: 14, weight: .medium))
                        Text(match.relativePath.isEmpty ? tree.rootPath : match.relativePath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    Text(ByteFormat.string(match.size))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onGo(match.node); dismiss() }
            }
            .listStyle(.inset)
        }
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Return to go \u{2022} Escape to cancel")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Go") { go() }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil && found.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func moveSelection(by delta: Int) {
        guard !found.isEmpty else { return }
        let current = found.firstIndex { $0.node == selection } ?? 0
        let next = min(max(current + delta, 0), found.count - 1)
        selection = found[next].node
    }

    private func go() {
        // An exact path wins over a name match, so pasting a full path is precise.
        if let exact = tree.node(atPath: query), tree.nodes[exact].isDirectory {
            onGo(exact)
            dismiss()
            return
        }
        if let node = selection ?? found.first?.node {
            onGo(node)
            dismiss()
        }
    }
}
