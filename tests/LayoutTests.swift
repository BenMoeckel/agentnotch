import AppKit

@main
struct LayoutTests {
    static func layout(_ active: Int, _ results: Int, camera: CGFloat = 180) -> NotchLayout {
        NotchLayout(activeCount: active, resultCount: results, cameraWidth: camera, height: 32)
    }
    static func main() {
        precondition(layout(0, 0).compactSize == CGSize(width: 180, height: 32))
        precondition(layout(0, 0, camera: 0).compactSize == CGSize(width: 16, height: 32))
        precondition(layout(1, 0).compactSize.width < layout(2, 0).compactSize.width)
        precondition(layout(2, 0).compactSize.width < layout(6, 0).compactSize.width)
        precondition(layout(0, 3).compactSize == layout(3, 0).compactSize)
        precondition(layout(3, 1).compactSize == layout(3, 3).compactSize)
        precondition(layout(7, 0).compactSize.width > layout(6, 0).compactSize.width)
        precondition(layout(100, 0).compactSize.width < 600, "Overflow must stay bounded")
        precondition(layout(2, 1).compactSize.width - layout(2, 1).sideWidth * 2 == 180)
        precondition(layout(1, 0, camera: 0).compactSize.height == 32)
        let external = NotchDetector.Display(frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
                                             topInset: 0, cameraWidth: 0, isBuiltIn: false)
        let laptop = NotchDetector.Display(frame: NSRect(x: -1512, y: -982, width: 1512, height: 982),
                                           topInset: 33.5, cameraWidth: 180, isBuiltIn: true)
        let camera = NotchDetector.geometry(for: [external, laptop])
        precondition(camera.frame.midX == laptop.frame.midX)
        precondition(camera.frame.maxY == laptop.frame.maxY)
        precondition(camera.topInset == 33.5 && camera.cameraWidth == 180)
        precondition(NotchDetector.geometry(for: [laptop, external]) == camera,
                     "Changing the primary monitor must not move the physical camera anchor")
        let rearranged = NotchDetector.Display(frame: NSRect(x: 2560, y: 400, width: 1512, height: 982),
                                               topInset: 37, cameraWidth: 190, isBuiltIn: true)
        let moved = NotchDetector.geometry(for: [external, rearranged])
        precondition(moved.frame.midX == rearranged.frame.midX && moved.frame.maxY == rearranged.frame.maxY)
        precondition(moved.topInset == 37 && moved.cameraWidth == 190)
        let closed = NotchDetector.geometry(for: [external])
        precondition(closed.frame.midX == external.frame.midX && closed.frame.maxY == external.frame.maxY)
        precondition(closed.cameraWidth == 0 && closed.frame.height == 28)
        precondition(NotchDetector.geometry(for: []).frame == .zero)
        print("PASS: empty state, count-based growth/shrinkage, camera alignment, overflow, display rearrangement and clamshell fallback")
    }
}
