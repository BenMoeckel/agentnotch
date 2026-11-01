import AppKit
import SwiftUI

private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    // This panel deliberately stays inactive. Plain SwiftUI buttons otherwise
    // discard their first click while another application is active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchPanel: NSPanel {
    private var anchor: NSRect
    private var requestedSize: CGSize
    private var repairScheduled = false

    init(frame: NSRect) {
        anchor = frame
        requestedSize = frame.size
        super.init(
            contentRect: frame,
            // HUD/utility chrome can add a thin top border even to a borderless
            // panel. SwiftUI draws the entire surface of this overlay.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        alphaValue = 0
        NotchSpaceManager.shared.add(window: self)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(restoreAnchor),
                                                   name: name, object: self)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // This overlay intentionally touches the physical screen edge. AppKit's
        // default constraints can move it down when it overlaps the menu bar.
        return frameRect
    }

    func updateAnchor(_ frame: NSRect) {
        anchor = frame
        resize(to: requestedSize)
    }

    // Retain the explicit anchor entry point for rendering callers.
    func resize(to size: CGSize, anchoredTo compactFrame: NSRect) {
        anchor = compactFrame
        resize(to: size)
    }

    @objc private func restoreAnchor(_ notification: Notification) {
        guard !repairScheduled else { return }
        repairScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.repairScheduled = false
            self.resize(to: self.requestedSize)
        }
    }

    func resize(to size: CGSize) {
        requestedSize = size
        // Keep the hosting view alive so incoming agents can reveal the panel.
        // A hidden panel must not leave an invisible mouse target in the menu bar.
        guard size.width > 0, size.height > 0, anchor.width > 0, anchor.height > 0 else {
            alphaValue = 0
            ignoresMouseEvents = true
            return
        }
        // Match AppKit's whole-point window size before computing the origin,
        // so fractional camera insets cannot move the top edge after rounding.
        // AppKit floors the origin as well; use that same frame to avoid
        // repeatedly repairing an unrepresentable half-point position.
        let windowSize = CGSize(width: ceil(size.width), height: ceil(size.height))
        let expandedFrame = NSRect(
            x: floor(anchor.midX - windowSize.width / 2),
            y: floor(anchor.maxY - windowSize.height),
            width: windowSize.width,
            height: windowSize.height
        )
        if frame != expandedFrame { setFrame(expandedFrame, display: true) }
        ignoresMouseEvents = false
        alphaValue = 1
    }

    func setContent<V: View>(@ViewBuilder _ view: () -> V) {
        // A plain AppKit container keeps SwiftUI's window sizing machinery out
        // of the panel's display cycle. Only resize(to:anchoredTo:) owns its frame.
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        // AppKit rounds panel frames to whole points (e.g. a 33.5pt camera
        // inset becomes a 34pt window). Anchor the fixed-size SwiftUI surface
        // to the actual top edge; the default centering leaves a visible seam.
        let hostingView = NotchHostingView(rootView: view()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        hostingView.sizingOptions = []
        // The camera clearance is handled explicitly by NotchBarView. AppKit's
        // automatic safe area would otherwise inset the top of this overlay.
        hostingView.safeAreaRegions = []
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        contentView = container
    }
}
