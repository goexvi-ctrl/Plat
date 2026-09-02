import PlatCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ScanModel
    @State private var hover: TreemapBox?
    @State private var inspection: Inspection?
    @State private var goToFolder = false

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 700, minHeight: 480)
        .toolbar { toolbarItems }
        .sheet(isPresented: $goToFolder) {
            GoToFolderView(tree: model.tree) { node in
                inspection = nil
                model.focus(on: node)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goToFolderRequested)) { _ in
            if model.isReady { goToFolder = true }
        }
        .navigationTitle(model.windowTitle)
    }

    // MARK: Main area

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .empty:
            placeholder(icon: "internaldrive",
                        title: "No folder scanned",
                        detail: "Choose a folder to see what is using its space.") {
                Button("Choose Folder\u{2026}") { model.chooseFolder() }
                    .buttonStyle(.borderedProminent)
            }

        case .scanning(let stats):
            // Report both sizes while scanning.  Showing only the logical total
            // would name a figure the map never uses, since on-disk is the
            // default; and the gap between the two is itself informative.
            let onDisk = model.splitHardLinks ? stats.sharedBytes : stats.allocatedBytes
            placeholder(icon: "magnifyingglass",
                        title: "Scanning\u{2026}",
                        detail: "\(ByteFormat.count(stats.files)) files in "
                              + "\(ByteFormat.count(stats.directories)) folders\n"
                              + "\(ByteFormat.string(onDisk)) on disk \u{2022} "
                              + "\(ByteFormat.string(stats.totalBytes)) logical") {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
            }

        case .failed(let message):
            placeholder(icon: "exclamationmark.triangle",
                        title: "Could not scan",
                        detail: message) {
                Button("Choose Folder\u{2026}") { model.chooseFolder() }
            }

        case .ready:
            ZStack(alignment: .topLeading) {
                TreemapView(tree: model.tree,
                            root: model.focus,
                            options: model.options,
                            showLabels: model.showLabels,
                            onOpen: { zoom(to: $0) },
                            onInspect: { node, point in
                                inspection = Inspection(node: node, point: point)
                            },
                            onGoUp: { model.goUp(); inspection = nil },
                            onHover: { hover = $0 })

                // A small invisible anchor sitting where the click landed, so
                // the popover's arrow points at the box the user hit.  The
                // treemap view is flipped, so its coordinates already match
                // SwiftUI's top-left origin.
                Color.clear
                    .frame(width: 16, height: 16)
                    .position(x: inspection?.point.x ?? 0, y: inspection?.point.y ?? 0)
                    .allowsHitTesting(false)
                    .popover(item: $inspection, arrowEdge: .bottom) { target in
                        InfoPanel(tree: model.tree,
                                  node: target.node,
                                  onZoom: { zoom(to: $0) })
                    }
            }
            .onChange(of: model.focus) { inspection = nil }
            .onChange(of: model.layout) { inspection = nil }
            .onChange(of: model.metric) { inspection = nil }
            .onChange(of: model.depthLimit) { inspection = nil }
        }
    }

    /// The depth field accepts a number or the word "All" (also blank, or 0).
    private var depthText: Binding<String> {
        Binding(get: { model.depthLimit == 0 ? "All" : String(model.depthLimit) },
                set: { entered in
                    let t = entered.trimmingCharacters(in: .whitespaces).lowercased()
                    if t.isEmpty || t == "all" {
                        model.depthLimit = 0
                    } else if let n = Int(t.filter(\.isNumber)) {
                        model.depthLimit = min(max(n, 0), ScanModel.maxDepthLimit)
                    }
                })
    }

    /// The clickable path, shown in the toolbar in place of a plain title.
    /// A path deeper than five levels collapses its leading elements into a
    /// menu, so the folder you are actually in never gets truncated away.
    @ViewBuilder
    private var pathWidget: some View {
        if model.phase == .ready {
            let crumbs = model.breadcrumb
            let tail = 4
            HStack(spacing: 3) {
                if crumbs.count > tail + 1 {
                    Menu {
                        ForEach(crumbs.dropLast(tail), id: \.self) { node in
                            Button(model.tree.displayPath(of: node)) { model.focus(on: node) }
                        }
                    } label: {
                        Text("\u{2026}")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Earlier folders in the path")
                    Text("/").foregroundStyle(.tertiary)
                    crumbRow(Array(crumbs.suffix(tail)))
                } else {
                    crumbRow(crumbs)
                }
                Text(ByteFormat.string(model.tree.size(of: model.focus)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    private func crumbRow(_ nodes: [Int]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(nodes.enumerated()), id: \.element) { index, node in
                if index > 0 { Text("/").foregroundStyle(.tertiary) }
                PathCrumb(name: model.tree.name(of: node),
                          destination: model.tree.displayPath(of: node),
                          isCurrent: node == model.focus) {
                    model.focus(on: node)
                }
            }
        }
    }

    private func zoom(to node: Int) {
        inspection = nil
        model.focus(on: node)
    }

    private func placeholder<Extra: View>(icon: String, title: String, detail: String,
                                          @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.title3)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            extra().padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Chrome

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let hover {
                if hover.isAggregate {
                    Text("\(ByteFormat.count(Int(hover.aggregatedCount))) items too small to draw")
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.tree.path(of: Int(hover.node)))
                        .lineLimit(1).truncationMode(.head)
                    Text(ByteFormat.string(model.tree.size(of: Int(hover.node))))
                        .monospacedDigit().foregroundStyle(.secondary)
                    if model.tree.isHardLinked(Int(hover.node)) {
                        Text("\(model.tree.nodes[Int(hover.node)].linkCount) hard links "
                             + "\u{2014} deleting this frees nothing")
                            .foregroundStyle(.red)
                    }
                }
            } else if case .ready = model.phase {
                Text("Click for details \u{2022} double-click to zoom in \u{2022} right-click to go back")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if case .ready = model.phase {
                Text("\(ByteFormat.count(model.tree.stats.files)) files, "
                     + "\(ByteFormat.count(model.tree.stats.directories)) folders, "
                     + String(format: "scanned in %.2fs", model.tree.stats.duration))
                    .foregroundStyle(.secondary).monospacedDigit()
                if model.tree.stats.hardLinkedFiles > 0 {
                    Text("\(ByteFormat.count(model.tree.stats.hardLinkedFiles)) hard-linked")
                        .foregroundStyle(.red)
                        .help("Files reachable under more than one name. Deleting one "
                              + "name frees nothing until the last one goes.")
                }
                if model.tree.stats.errors > 0 {
                    Text("\(ByteFormat.count(model.tree.stats.errors)) unreadable")
                        .foregroundStyle(.orange)
                        .help("Entries that could not be read, usually because macOS "
                              + "privacy settings withhold them from this app.")
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 24)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // The path lives in the toolbar rather than in a bar of its own: a
        // window title cannot be clicked, and a separate strip costs a row of
        // vertical space for something the title bar already has room for.
        ToolbarItem(placement: .navigation) {
            pathWidget
        }
        ToolbarItemGroup {
            Button { model.goUp() } label: { Image(systemName: "arrow.up.left") }
                .help("Go up one level")
                .disabled(!model.canGoUp)

            Button { model.chooseFolder() } label: { Image(systemName: "folder") }
                .help("Choose a folder to scan")

            Button { goToFolder = true } label: { Image(systemName: "magnifyingglass") }
                .help("Go to a folder by name, without rescanning")
                .disabled(!model.isReady)

            Button { model.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .help("Scan again")
                .disabled(model.scannedPath == nil || model.isScanning)

            HStack(spacing: 3) {
                Image(systemName: "square.3.layers.3d.down.right")
                TextField("All", text: depthText)
                    .frame(width: 40)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: $model.depthLimit,
                        in: 0 ... ScanModel.maxDepthLimit)
                    .labelsHidden()
            }
            .help("How many levels of folders to draw. \"All\" (or 0) draws every "
                  + "level; type a number, or use the arrows.")

            Picker("Measure", selection: $model.metric) {
                ForEach(SizeMetric.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .help("Sparse and compressed files occupy far less disk than their "
                  + "apparent length; \"Size on disk\" is what deleting them frees.")

            Picker("Layout", selection: $model.layout) {
                ForEach(TreemapLayout.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
            .help("How boxes are arranged")

            Toggle(isOn: $model.showLabels) { Image(systemName: "textformat") }
                .help("Show names inside boxes")
        }
    }
}

/// One element of the path bar.
///
/// Deliberately not `.buttonStyle(.link)`: a link-styled button takes clicks
/// only on the glyphs themselves, which for a short folder name is a target a
/// few points wide and easy to miss entirely.  A plain button with an explicit
/// `contentShape` makes the whole padded rectangle clickable, and the hover
/// highlight makes it obvious which parts of the path are targets.
private struct PathCrumb: View {
    let name: String
    let destination: String
    let isCurrent: Bool
    var go: () -> Void

    @State private var hovering = false

    var body: some View {
        if isCurrent {
            // Where you already are; nothing to click.
            Text(name)
                .fontWeight(.medium)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        } else {
            Button(action: go) {
                Text(name)
                    .foregroundStyle(hovering ? AnyShapeStyle(Color.accentColor)
                                              : AnyShapeStyle(.primary))
                    .underline(hovering)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(hovering ? 0.18 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Go to \(destination)")
        }
    }
}
