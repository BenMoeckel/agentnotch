import SwiftUI

struct NotchShape: Shape {
    var cornerRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = cornerRadius
        // Top edge overdraws past the screen edge so the antialiased clip seam falls off-screen
        let topY = rect.minY - 2
        // Outer top-left → notch left curve → bottom → notch right curve → outer top-right
        p.move(to: CGPoint(x: rect.minX, y: topY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: topY))
        p.closeSubpath()
        return p
    }
}
