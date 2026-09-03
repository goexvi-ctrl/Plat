import AppKit
import PlatCore
import SwiftUI

final class TreemapNSView: NSView {

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
    var onHover: ((TreemapBox?) -> Void)?

    private var map = Treemap.empty
    private var mapBounds: CGRect = .zero
    private var mapDirty = true
    private var hovered: TreemapBox?
    private var tracking: NSTrackingArea?
    private var renderer = TreemapRenderer()
    private var themeAppearance: NSAppearance.Name?
    private var themeDirty = true

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
        window?.makeFirstResponder(self)
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

    private func point(from event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        layoutIfNeeded()
        let hit = map.hitTestBox(point(from: event))
        guard hit?.node != hovered?.node || hit?.rect != hovered?.rect else { return }
        // Repaint only the two boxes whose highlight changed.
        for r in [hovered?.rect, hit?.rect].compactMap({ $0 }) {
            setNeedsDisplay(r.insetBy(dx: -3, dy: -3))
        }
        hovered = hit
        onHover?(hit)
    }

    override func mouseExited(with event: NSEvent) {
        if let r = hovered?.rect { setNeedsDisplay(r.insetBy(dx: -3, dy: -3)) }
        hovered = nil
        onHover?(nil)
    }

    /// A single click describes the box under the pointer; a double click zooms
    /// into it.  Either way hit testing walks the cached layout -- the original
    /// re-ran the whole treemap computation on every click just to find the box.
    override func mouseDown(with event: NSEvent) {
        layoutIfNeeded()
        let p = point(from: event)
        guard let node = map.hitTest(p) else { return }
        if event.clickCount >= 2 {
            onOpen?(node)
        } else {
            onInspect?(node, p)
        }
    }

    override func rightMouseDown(with event: NSEvent) { onGoUp?() }

    /// Delete acts on the box under the pointer, which is the one the user is
    /// looking at.  Nothing happens without a target, and the model still puts
    /// a confirmation in the way.
    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]   // delete, forward delete
        guard deleteKeys.contains(event.keyCode), let node = hovered?.node else {
            super.keyDown(with: event)
            return
        }
        onDelete?(Int(node))
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
    }
}
