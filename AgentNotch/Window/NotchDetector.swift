import AppKit
import Combine

/// Symmetric wings keep the central gap aligned with the physical camera.
struct NotchLayout {
    static let iconLimit = 6
    let activeCount: Int
    let resultCount: Int
    let cameraWidth: CGFloat
    let height: CGFloat

    var isEmpty: Bool { activeCount == 0 && resultCount == 0 }
    var gap: CGFloat { cameraWidth > 0 ? cameraWidth : 16 }

    private func wingWidth(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let icons = min(count, Self.iconLimit)
        let overflow = count > Self.iconLimit
            ? 8 + CGFloat(String(count - Self.iconLimit).count + 1) * 7 : 0
        return 24 + CGFloat(icons) * 14 + CGFloat(icons - 1) * 8 + overflow
    }

    var sideWidth: CGFloat { max(wingWidth(for: activeCount), wingWidth(for: resultCount)) }
    var compactSize: CGSize {
        // Even with no agents the panel stays present as a hover target over the
        // camera area, so it can always be opened. Empty wings keep it minimal.
        CGSize(width: gap + sideWidth * 2, height: height)
    }
}

/// One snapshot supplies both the window anchor and the SwiftUI camera gap.
struct NotchGeometry: Equatable {
    let frame: NSRect
    let topInset: CGFloat
    let cameraWidth: CGFloat
}

final class NotchPlacement: ObservableObject {
    @Published var geometry = NotchDetector.geometry()
}

enum NotchDetector {
    struct Display {
        let frame: NSRect
        let topInset: CGFloat
        let cameraWidth: CGFloat
        let isBuiltIn: Bool
    }

    static func geometry() -> NotchGeometry {
        let displays = NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let cameraWidth: CGFloat
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                cameraWidth = max(0, right.minX - left.maxX)
            } else {
                cameraWidth = 0
            }
            return Display(frame: screen.frame, topInset: screen.safeAreaInsets.top,
                           cameraWidth: cameraWidth, isBuiltIn: id.map { CGDisplayIsBuiltin($0) != 0 } ?? false)
        }
        return geometry(for: displays)
    }

    static func geometry(for displays: [Display]) -> NotchGeometry {
        // NSScreen.main follows the focused window, so it is not a stable anchor.
        // Prefer the physical camera; in clamshell mode use the primary display
        // (the first NSScreen), independent of focus or pointer location.
        guard let display = displays.first(where: { $0.isBuiltIn && $0.cameraWidth > 0 })
                ?? displays.first(where: { $0.cameraWidth > 0 })
                ?? displays.first(where: { $0.isBuiltIn })
                ?? displays.first else {
            return NotchGeometry(frame: .zero, topInset: 0, cameraWidth: 0)
        }
        let height = display.cameraWidth > 0 ? display.topInset : 28
        let width = display.cameraWidth > 0 ? display.cameraWidth + 176 : 220
        return NotchGeometry(
            frame: NSRect(x: display.frame.midX - width / 2,
                          y: display.frame.maxY - height, width: width, height: height),
            topInset: display.cameraWidth > 0 ? display.topInset : 0,
            cameraWidth: display.cameraWidth
        )
    }
}
