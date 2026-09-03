import AppKit
import PlatCore
import SwiftUI

final class TreemapNSView: NSView, NSDraggingSource {

    var tree: FileTree = .empty { didSet { invalidate() } }
    var rootNode: Int = 0 { didSet { invalidate() } }
    var options = TreemapOptions() { didSet { invalidate() } }
    var showLabels = true { didSet { needsDisplay = true } }
    /// Not `appearance`: NSView already has a property by that name.
    var themeSettings = AppearanceSettings() {
        didSet { if themeSettings != oldValue { themeDirty = true; needsDisplay = true } }
    }

    var onOpen: ((Int) -> Void)?
    var onInspect: ((Int, CGPoint) -> Void)?
    var onGoUp: (() -> Void)?
    var onDelete: ((Int) -> Void)?
    var onPreview: ((Int, CGPoint) -> Void)?
    var onHover: ((TreemapBox?) -> Void)?
    /// Whether this item may be moved out of Plat, as opposed to only copied.
    var allowsMove: ((Int) -> Bool)?
    /// A drag finished.  The flag says whether the drop target *claimed* it
    /// would take the file away, which is a hint about how long to keep
    /// looking -- never an answer about what happened.
    var onDragEnded: ((Int, Bool) -> Void)?

    private var map = Treemap.empty
    private var mapBounds: CGRect = .zero
    private var mapDirty = true
    private var hovered: TreemapBox?
    private var tracking: NSTrackingArea?
    private var renderer = TreemapRenderer()
    private let tooltip = MapTooltip()
    private var themeAppearance: NSAppearance.Name?
    private var themeDirty = true
    /// Where the mouse went down, and on what, so a drag can be told from a
    /// click without acting on either too early.
    private var pressPoint: CGPoint?
    private var pressNode: Int?
    private var dragging = false
    private var dragNode: Int?
    private var dragMask: NSDragOperation = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func invalidate() {
        mapDirty = true
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidate()
    }

    /// Rebuild the layout only when something it depends on actually changed.
    /// Repaints caused by hover, exposure or window activation reuse it; the
    /// original recomputed the entire treemap on every one of those.
    private func layoutIfNeeded() {
        let b = bounds
        guard mapDirty || b != mapBounds else { return }
        map = Treemap.build(tree: tree, root: rootNode, bounds: b, options: options)
        mapBounds = b
        mapDirty = false
    }

    /// Rebuild the palette only when the system appearance changes.
    private func themeIfNeeded() {
        let name = effectiveAppearance.name
        guard themeDirty || themeAppearance != name else { return }
        themeAppearance = name
        themeDirty = false
        var theme = RenderTheme.standard
        effectiveAppearance.performAsCurrentDrawingAppearance {
            theme.background = NSColor.textBackgroundColor.cgColor
            theme.label = NSColor.labelColor.cgColor
            theme.highlight = NSColor.controlAccentColor.cgColor
            let dark = name == .darkAqua || name == .vibrantDark
            theme.container = CGColor(gray: dark ? 0.75 : 0.5, alpha: dark ? 0.14 : 0.10)
            theme.outline = CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.30 : 0.28)
            theme.aggregate = CGColor(gray: dark ? 0.62 : 0.55, alpha: 0.35)
            theme.collapsed = CGColor(red: 0.42, green: 0.53, blue: 0.68,
                                      alpha: dark ? 0.65 : 0.55)
            theme.linkMark = CGColor(red: dark ? 1.0 : 0.85, green: dark ? 0.42 : 0.12,
                                     blue: dark ? 0.42 : 0.20, alpha: 0.95)
        }
        // User choices sit on top of the system-adaptive base, so an untouched
        // slot still follows light and dark.
        renderer = TreemapRenderer(theme: themeSettings.apply(to: theme),
                                   fontName: themeSettings.mapFontName,
                                   fontSize: CGFloat(themeSettings.mapFontSize))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        layoutIfNeeded()
        themeIfNeeded()
        renderer.showLabels = showLabels
        renderer.draw(map, of: tree, in: context, clip: dirtyRect, highlight: hovered?.rect)
    }

    // MARK: Interaction

    /// Take key focus when the map appears, so Delete works without a click
    /// first.  Nothing else in the window wants the keyboard until a sheet or
    /// popover opens, and those take it back for as long as they are up.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tooltip.hide()
        guard let window else { return }
        window.makeFirstResponder(self)
        // Tracking is .activeInKeyWindow, so a window losing key stops sending
        // mouseMoved -- and would strand a tooltip on screen.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tooltip.hide() }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// Just the name.  The status bar already carries the full path, and a
    /// tooltip that repeats it covers the map with something the eye has to
    /// parse; the name is what a box too small to label is missing.
    private func tooltipText(for box: TreemapBox?) -> String? {
        guard let box else { return nil }
        if box.isAggregate {
            return "\(ByteFormat.count(Int(box.aggregatedCount))) smaller items"
        }
        return tree.name(of: Int(box.node))
    }

    private func point(from event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        layoutIfNeeded()
        let hit = map.hitTestBox(point(from: event))
        // Feed the tooltip on every move, not only when the box changes: while
        // it is up it follows the pointer.
        if let screen = window?.convertPoint(toScreen: event.locationInWindow) {
            tooltip.track(tooltipText(for: hit), at: screen)
        }
        guard hit?.node != hovered?.node || hit?.rect != hovered?.rect else { return }
        // Repaint only the two boxes whose highlight changed.
        for r in [hovered?.rect, hit?.rect].compactMap({ $0 }) {
            setNeedsDisplay(r.insetBy(dx: -3, dy: -3))
        }
        hovered = hit
        onHover?(hit)
    }

    override func mouseExited(with event: NSEvent) {
        tooltip.hide()
        if let r = hovered?.rect { setNeedsDisplay(r.insetBy(dx: -3, dy: -3)) }
        hovered = nil
        onHover?(nil)
    }

    /// A single click describes the box under the pointer; a double click zooms
    /// into it.  Either way hit testing walks the cached layout -- the original
    /// re-ran the whole treemap computation on every click just to find the box.
    override func mouseDown(with event: NSEvent) {
        tooltip.hide()
        // Take the keyboard back: a sheet or popover may have had it, and
        // Delete and Q are aimed at whatever the pointer is over.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        layoutIfNeeded()
        let p = point(from: event)
        pressPoint = p
        pressNode = map.hitTest(p)
        dragging = false
    }

    /// Past a few points of travel this is a drag, not a click.  Acting on
    /// mouse-up rather than mouse-down is what makes room for that; it is also
    /// the ordinary macOS behaviour for anything draggable.
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = pressPoint, let node = pressNode else { return }
        let p = point(from: event)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragging = true
        beginDrag(node: node, at: start, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil; pressNode = nil }
        guard !dragging, let node = pressNode else { return }
        if event.clickCount >= 2 {
            onOpen?(node)
        } else {
            onInspect?(node, point(from: event))
        }
    }

    override func rightMouseDown(with event: NSEvent) { onGoUp?() }

    // MARK: Dragging out

    private func beginDrag(node: Int, at origin: CGPoint, event: NSEvent) {
        tooltip.hide()
        let entry = tree.nodes[node]
        // A capacity block is not a file, and a deleted one is not there.
        guard !entry.isSynthetic, !tree.isGone(node) else { return }
        let path = tree.path(of: node)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)

        // Copy only unless the item is safe to move.  There is no moment in a
        // drag at which Plat could put a warning, so the protection has to be
        // in what it offers: dragging one file out of an application bundle
        // breaks the bundle, and the drop target would do it without asking.
        // Refusing the move makes the Finder show a copy badge instead.
        dragMask = (allowsMove?(node) ?? false) ? [.copy, .move, .delete] : [.copy]
        dragNode = node

        let icon = NSWorkspace.shared.icon(forFile: path)
        let side: CGFloat = 48
        icon.size = NSSize(width: side, height: side)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: origin.x - side / 2, y: origin.y - side / 2,
                                     width: side, height: side),
                              contents: icon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// Delete acts on the box under the pointer, which is the one the user is
    /// looking at.  Nothing happens without a target, and the model still puts
    /// a confirmation in the way.
    override func keyDown(with event: NSEvent) {
        guard let box = hovered, !box.isAggregate else {
            super.keyDown(with: event)
            return
        }
        let node = Int(box.node)
        let deleteKeys: Set<UInt16> = [51, 117]   // delete, forward delete
        if deleteKeys.contains(event.keyCode) {
            tooltip.hide()
            onDelete?(node)
            return
        }
        // Command-Q is the Quit menu item's key equivalent, dispatched before
        // this, so a bare "q" cannot be mistaken for it.  Space is here because
        // it is what the Finder uses.
        let typed = event.charactersIgnoringModifiers?.lowercased()
        if !event.modifierFlags.contains(.command), typed == "q" || typed == " " {
            tooltip.hide()
            onPreview?(node, CGPoint(x: box.rect.midX, y: box.rect.midY))
            return
        }
        super.keyDown(with: event)
    }
}

extension TreemapNSView {

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Dropping a box back onto the map would mean nothing, so only drags
        // that leave Plat do anything at all.
        context == .outsideApplication ? dragMask : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        defer { dragging = false; dragNode = nil }
        guard let node = dragNode else { return }
        // `operation` is what the destination said it would do, negotiated by
        // the system -- not a record of what it did.  An application that opens
        // an image and touches nothing still has to answer something, and
        // .copy or .generic are the conventional answers; .generic in
        // particular means nothing at all about the filesystem.  So the truth
        // comes from the disk, and this only says whether to expect a change.
        let claimsRemoval = !operation.intersection([.move, .delete]).isEmpty
        onDragEnded?(node, claimsRemoval)
    }
}

struct TreemapView: NSViewRepresentable {
    var tree: FileTree
    var root: Int
    var options: TreemapOptions
    var showLabels: Bool
    var appearance: AppearanceSettings
    var onOpen: (Int) -> Void
    var onInspect: (Int, CGPoint) -> Void
    var onGoUp: () -> Void
    var onHover: (TreemapBox?) -> Void
    var onDelete: (Int) -> Void
    var onPreview: (Int, CGPoint) -> Void
    var allowsMove: (Int) -> Bool
    var onDragEnded: (Int, Bool) -> Void

    func makeNSView(context: Context) -> TreemapNSView {
        let v = TreemapNSView()
        apply(to: v)
        return v
    }

    func updateNSView(_ v: TreemapNSView, context: Context) { apply(to: v) }

    /// Assign only what changed -- every setter throws the cached layout away.
    private func apply(to v: TreemapNSView) {
        if v.rootNode != root { v.rootNode = root }
        if v.tree.nodes.count != tree.nodes.count || v.tree.rootPath != tree.rootPath
            || v.tree.metric != tree.metric
            || v.tree.revision != tree.revision
            || v.tree.splitHardLinks != tree.splitHardLinks {
            v.tree = tree
        }
        if v.options.layout != options.layout
            || v.options.labelHeight != options.labelHeight
            || v.options.maxDepth != options.maxDepth
            || v.options.collapsePackages != options.collapsePackages {
            v.options = options
        }
        v.showLabels = showLabels
        v.themeSettings = appearance
        v.onOpen = onOpen
        v.onInspect = onInspect
        v.onGoUp = onGoUp
        v.onHover = onHover
        v.onDelete = onDelete
        v.onPreview = onPreview
        v.allowsMove = allowsMove
        v.onDragEnded = onDragEnded
    }
}
