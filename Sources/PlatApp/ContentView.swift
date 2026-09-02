import PlatCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ScanModel
    @State private var hover: TreemapBox?
    @State private var inspection: Inspection?
    @State private var goToFolder = false

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
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
        .navigationTitle(model.scannedPath.map { ($0 as NSString).lastPathComponent } ?? "Plat")
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
            placeholder(icon: "magnifyingglass",
                        title: "Scanning\u{2026}",
                        detail: "\(ByteFormat.count(stats.files)) files in "
                              + "\(ByteFormat.count(stats.directories)) folders \u{2014} "
                              + ByteFormat.string(stats.totalBytes)) {
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

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if model.phase == .ready {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button(model.tree.name(of: node)) { model.focus(on: node) }
                            .buttonStyle(.link)
                            .disabled(node == model.focus)
                    }
                    Spacer(minLength: 12)
                    Text(ByteFormat.string(model.tree.size(of: model.focus)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(model.metric.shortName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(model.scannedPath ?? "Plat").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 28)
    }

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
