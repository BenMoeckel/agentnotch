import AppKit
import SwiftUI

// Run from the repository root (macOS with Xcode/SwiftUI):
// xcrun swiftc -module-cache-path build/ModuleCache.noindex \
//   -o /private/tmp/agentnotch-panel-rendering-tests \
//   AgentNotch/Window/NotchPanel.swift AgentNotch/Window/NotchSpaceManager.swift \
//   AgentNotch/Window/CGSSpace.swift AgentNotch/Views/NotchShape.swift \
//   tests/PanelRenderingTests.swift
// /private/tmp/agentnotch-panel-rendering-tests
// No window is ordered onscreen and no screen-recording permission is needed.

@MainActor
private final class SurfaceSize: ObservableObject {
    @Published var value = CGSize(width: 261, height: 34)
}

private struct TestSurface: View {
    @ObservedObject var size: SurfaceSize

    var body: some View {
        Color.clear
            .frame(width: size.value.width, height: size.value.height)
            .background(Color.black)
            .clipShape(NotchShape())
    }
}

@MainActor
private protocol RootViewSnapshotting {
    func snapshot(scale: CGFloat) -> NSBitmapImageRep
}

extension NSHostingView: RootViewSnapshotting {
    fileprivate func snapshot(scale: CGFloat) -> NSBitmapImageRep {
        // Use the production rootView inside a viewport matching the actual
        // AppKit-rounded host. No alignment modifier is supplied by the test.
        let renderer = ImageRenderer(content: rootView.frame(width: bounds.width,
                                                             height: bounds.height))
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            fatalError("Cannot render the panel's production hosting root")
        }
        return NSBitmapImageRep(cgImage: image)
    }
}

@main
struct PanelRenderingTests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = SurfaceSize()
        let anchor = NSRect(x: 100.5, y: 966.5, width: 261, height: 33.5)
        let panel = NotchPanel(frame: anchor)
        panel.setContent { TestSurface(size: model) }
        defer { panel.close() }
        let container = panel.contentView!
        let hosting = container.subviews.first!
        precondition(hosting.acceptsFirstMouse(for: nil),
                     "Session buttons must accept the first click while the notch remains inactive")

        // Exercise the same hosting view through integer sizing, the reported
        // 33.5 -> 34pt compact rounding, expansion and repeated collapse.
        let sizes = [CGSize(width: 261, height: 34),
                     CGSize(width: 261, height: 33.5),
                     CGSize(width: 600, height: 137.5),
                     CGSize(width: 261, height: 33.5),
                     CGSize(width: 600, height: 345.5),
                     CGSize(width: 261, height: 34)]
        for size in sizes {
            model.value = size
            panel.resize(to: size, anchoredTo: anchor)
            container.layoutSubtreeIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            precondition(!panel.isVisible, "Rendering tests must remain offscreen")
            precondition(container.subviews.first === hosting, "Resizing must preserve the host")
            precondition(panel.frame.maxY == anchor.maxY, "Resizing moved the top screen anchor")
            precondition(hosting.bounds.size == panel.frame.size)
            precondition(hosting.bounds.height == ceil(size.height),
                         "Test must exercise AppKit's actual whole-point window rounding")

            // cacheDisplay does not reproduce this layout seam on a hidden
            // window. Render its real rootView at both backing scales instead.
            for scale: CGFloat in [1, 2] {
                let bitmap = (hosting as! RootViewSnapshotting).snapshot(scale: scale)
                precondition(bitmap.pixelsWide == Int(hosting.bounds.width * scale))
                precondition(bitmap.pixelsHigh == Int(hosting.bounds.height * scale))
                for y in 0..<2 {
                    for x in 2..<(bitmap.pixelsWide - 2) {
                        let pixel = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        precondition(pixel.alphaComponent > 0.99 &&
                                     pixel.redComponent < 0.01 &&
                                     pixel.greenComponent < 0.01 &&
                                     pixel.blueComponent < 0.01,
                                     "Top seam: surface \(size), host \(hosting.bounds.size), " +
                                     "scale \(scale), pixel (\(x), \(y)) = \(pixel)")
                    }
                }
                precondition(bitmap.colorAt(x: 0, y: bitmap.pixelsHigh - 1)!.alphaComponent < 0.01,
                             "Rounded lower corners must remain transparent")
            }
        }
        let newAnchor = NSRect(x: -1300, y: -34, width: 261, height: 34)
        panel.updateAnchor(newAnchor)
        precondition(panel.frame.midX == newAnchor.midX && panel.frame.maxY == newAnchor.maxY)
        panel.setFrameOrigin(NSPoint(x: 400, y: 200))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(panel.frame.midX == newAnchor.midX && panel.frame.maxY == newAnchor.maxY,
                     "System-driven window movement must be repaired without hover")
        panel.resize(to: CGSize(width: 600, height: 240))
        precondition(abs(panel.frame.midX - newAnchor.midX) <= 0.5 && panel.frame.maxY == newAnchor.maxY,
                     "Queued size updates must use the current display anchor")
        let settledFrame = panel.frame
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(panel.frame == settledFrame, "Rounded frames must settle without a repair loop")
        panel.updateAnchor(.zero)
        precondition(panel.alphaValue == 0 && panel.ignoresMouseEvents)
        panel.updateAnchor(newAnchor)
        precondition(panel.alphaValue == 1 && !panel.ignoresMouseEvents)
        precondition(!panel.isMovable && !panel.isMovableByWindowBackground)
        print("PASS: first-click acceptance, opaque top pixels at 1x/2x, display reanchoring and automatic position repair")
    }
}
