import PlatCore
import SwiftUI

extension Notification.Name {
    static let goToFolderRequested = Notification.Name("GoToFolderRequested")
}

@main
struct PlatApp: App {
    @State private var model = ScanModel()

    var body: some Scene {
        Window("Plat", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
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
