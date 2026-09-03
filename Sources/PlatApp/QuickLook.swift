import AppKit
import QuickLookUI

/// Drives the shared Quick Look panel -- the same one the Finder uses.
///
/// Quick Look is not Finder-only: `QLPreviewPanel` is a system-wide singleton
/// any app can present, as long as something supplies it with items.  The data
/// source has to outlive the call, hence the shared instance.
@MainActor
final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource,
                       @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private var url: URL?
    /// What to do if Delete is pressed while the preview is up.
    private var deleteAction: (() -> Void)?

    private override init() { super.init() }

    /// True when the file still exists; the scan may be minutes old by now.
    static func canPreview(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Show the preview.  `onDelete` runs if Delete is pressed while it is up,
    /// after the panel has closed.
    func show(_ path: String, onDelete: (() -> Void)? = nil) {
        guard Self.canPreview(path), let panel = QLPreviewPanel.shared() else { return }
        url = URL(fileURLWithPath: path)
        deleteAction = onDelete
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Quick Look offers this to anything that wants a crack at the keys it
    /// does not use itself, which is how Delete reaches Plat while the panel
    /// has the key window.  Looking at a file and deciding it is junk is one
    /// motion; making someone dismiss the preview first breaks it in half.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let deleteKeys: Set<UInt16> = [51, 117]   // delete, forward delete
        guard deleteKeys.contains(event.keyCode), let action = deleteAction else {
            return false
        }
        // Close first: the confirmation is a sheet on the main window, and it
        // cannot come up underneath a panel that owns the key window.  The hop
        // through the queue lets the panel finish going away.
        panel.orderOut(nil)
        DispatchQueue.main.async(execute: action)
        return true
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}
