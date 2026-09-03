import AppKit
import QuickLookUI

/// Drives the shared Quick Look panel -- the same one the Finder uses.
///
/// Quick Look is not Finder-only: `QLPreviewPanel` is a system-wide singleton
/// any app can present, as long as something supplies it with items.  The data
/// source has to outlive the call, hence the shared instance.
@MainActor
final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLook()

    private var url: URL?

    private override init() { super.init() }

    /// True when the file still exists; the scan may be minutes old by now.
    static func canPreview(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func show(_ path: String) {
        guard Self.canPreview(path), let panel = QLPreviewPanel.shared() else { return }
        url = URL(fileURLWithPath: path)
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}
