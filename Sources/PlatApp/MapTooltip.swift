import AppKit

/// The map's own tooltip.
///
/// AppKit's tooltips are registered per rectangle and arm once per entry: with
/// a single rect covering the whole view -- the only registration that can
/// scale, since a scan draws thousands of boxes and replaces all of them on
/// every resize -- the first tooltip shown is the last, until the pointer
/// leaves the view entirely and comes back.  Registering a rect per box is what
/// the 2004 build attempted, and it does not scale.
///
/// So the panel is ours.  It appears after the usual delay, follows the pointer
/// while it is up, and swaps its text the moment the pointer crosses into
/// another box, with no second wait.
@MainActor
final class MapTooltip {

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var countdown: DispatchWorkItem?
    /// Text waiting out the delay, and text currently on screen.  Exactly one
    /// of these is set at a time.
    private var pending: String?
    private var showing: String?
    private var target: NSPoint = .zero

    /// The system's own initial delay when it has been set, which is where a
    /// person who has opinions about tooltip timing will have set it.
    private static var delay: TimeInterval {
        if let ms = UserDefaults.standard.object(forKey: "NSInitialToolTipDelay") as? Double,
           ms > 0 {
            return ms / 1000
        }
        return 0.55
    }

    /// Report what is under the pointer, in screen coordinates.  Pass nil for
    /// "nothing".
    func track(_ text: String?, at screenPoint: NSPoint) {
        guard let text, !text.isEmpty else { hide(); return }
        target = screenPoint

        // Already up: follow the pointer, and change the words at once.  Making
        // the reader wait again to learn the name of the box they have just
        // moved onto is the behaviour that made the old one feel broken.
        if showing != nil {
            showing = text
            present(text)
            return
        }
        // Still counting down on this same box: keep the countdown running
        // rather than restarting it, so drifting inside one box still gets a
        // tooltip.
        if pending == text { return }

        countdown?.cancel()
        pending = text
        let work = DispatchWorkItem { [weak self] in
            guard let self, let waiting = pending else { return }
            pending = nil
            showing = waiting
            present(waiting)
        }
        countdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func hide() {
        countdown?.cancel()
        countdown = nil
        pending = nil
        showing = nil
        panel?.orderOut(nil)
    }

    // MARK: The panel

    private func present(_ text: String) {
        let panel = panel ?? makePanel()
        label.stringValue = text
        label.sizeToFit()

        let pad = NSSize(width: 8, height: 4)
        let size = NSSize(width: label.frame.width + pad.width * 2,
                          height: label.frame.height + pad.height * 2)
        label.setFrameOrigin(NSPoint(x: pad.width, y: pad.height))

        // Below and to the right, clear of the pointer, then nudged back onto
        // the screen it is actually on.
        var origin = NSPoint(x: target.x + 12, y: target.y - size.height - 18)
        let screen = NSScreen.screens.first { $0.frame.contains(target) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            // No room below: put it above the pointer instead.
            if origin.y < visible.minY + 4 { origin.y = target.y + 18 }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        // It must never take the pointer: the map is tracking the pointer to
        // decide what the tooltip should say.
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle,
                                .fullScreenAuxiliary]
        p.animationBehavior = .none

        let effect = NSVisualEffectView()
        effect.material = .toolTip
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 5
        effect.layer?.masksToBounds = true

        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBezeled = false
        label.lineBreakMode = .byTruncatingMiddle
        effect.addSubview(label)

        p.contentView = effect
        panel = p
        return p
    }
}
