import AppKit

final class NotchSpaceManager {
    static let shared = NotchSpaceManager()

    private let cid: CGSConnectionID
    private let space: CGSSpaceID

    private init() {
        cid = CGSDefaultConnection()
        space = CGSSpaceCreate(cid, 0, nil)
        CGSSpaceSetAbsoluteLevel(cid, space, Int.max)
        CGSShowSpaces(cid, [space] as CFArray)
    }

    func add(window: NSWindow) {
        CGSAddWindowsToSpaces(cid, [window.windowNumber] as CFArray, [space] as CFArray)
    }

    func remove(window: NSWindow) {
        CGSRemoveWindowsFromSpaces(cid, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}
