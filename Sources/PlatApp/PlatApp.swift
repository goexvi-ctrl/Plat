import AppKit
import PlatCore
import SwiftUI

extension Notification.Name {
    static let goToFolderRequested = Notification.Name("GoToFolderRequested")
}

@MainActor
private func showAboutPanel() {
    let build = BuildInfo.current
    let body = NSMutableParagraphStyle()
    body.alignment = .center

    let credits = NSMutableAttributedString()
    func line(_ text: String, size: CGFloat, colour: NSColor) {
        credits.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: colour,
            .paragraphStyle: body,
        ]))
    }
    line("A disk-usage treemap.", size: 11, colour: .labelColor)
    if !build.commitHash.isEmpty {
        line("Commit \(build.commitHash), \(build.commitDate)", size: 10, colour: .secondaryLabelColor)
    }
    if build.isModified {
        // Say so plainly: a build from a dirty tree does not correspond to any
        // commit, so the hash alone would be misleading.
        let when = build.buildTime.isEmpty ? "" : " at \(build.buildTime)"
        line("Built from a modified tree\(when)", size: 10, colour: .systemOrange)
    }

    NSApplication.shared.orderFrontStandardAboutPanel(options: [
        .applicationName: "Plat",
        .applicationVersion: build.version,
        .version: build.buildDetail,
        .credits: credits,
    ])
    NSApplication.shared.activate(ignoringOtherApps: true)
}

@main
struct PlatApp: App {
    @State private var model = ScanModel()
    @State private var prefs = Preferences()

    var body: some Scene {
        Window("Plat", id: "main") {
            ContentView(model: model, prefs: prefs)
        }
        .defaultSize(width: 1100, height: 720)

        // A Settings scene gives the standard Plat > Settings item and Cmd-,.
        Settings {
            SettingsView(prefs: prefs, model: model)
        }
        .commands {
            // Replace the stock About item so the panel can show which commit
            // this build came from, and whether the tree was clean.
            CommandGroup(replacing: .appInfo) {
                Button("About Plat") { showAboutPanel() }
            }
            // Plat has nothing else to undo, so the standard Edit > Undo slot
            // is exactly the right home for taking a delete back.
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoDeleteTitle) { model.undoDelete() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndoDelete)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder\u{2026}") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Go to Folder\u{2026}") {
                    NotificationCenter.default.post(name: .goToFolderRequested, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp)
                Button("Back to Top") { model.goToRoot() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Divider()
                Button("Show One Level Deeper") {
                    model.depthLimit = model.depthLimit == 0
                        ? ScanModel.maxDepthLimit
                        : min(model.depthLimit + 1, ScanModel.maxDepthLimit)
                }
                .keyboardShortcut("]", modifiers: .command)
                Button("Show One Level Less") {
                    // Stepping down from "All" starts at a useful shallow depth
                    // rather than at the cap.
                    model.depthLimit = model.depthLimit == 0 ? 3 : max(1, model.depthLimit - 1)
                }
                .keyboardShortcut("[", modifiers: .command)
                Button("Show All Levels") { model.depthLimit = 0 }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Divider()
                Toggle("Split Hard-Linked Space", isOn: $model.splitHardLinks)
                    .disabled(model.metric != .onDisk)
                Divider()
                Button("Scan Again") { model.rescan() }
                    .keyboardShortcut("r")
            }
        }
    }
}
