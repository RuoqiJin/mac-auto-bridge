import CoreGraphics

final class DisplayManager: @unchecked Sendable {

    static let shared = DisplayManager()

    func listDisplays() -> [DisplayInfo] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &displayCount)

        return (0..<Int(displayCount)).map { i in
            let id = displayIDs[i]
            let bounds = CGDisplayBounds(id)
            let scale = scaleFor(display: id)
            return DisplayInfo(displayID: id, bounds: bounds, scale: scale)
        }
    }

    func scaleFor(display: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return 2.0 }
        let bounds = CGDisplayBounds(display)
        guard bounds.width > 0 else { return 2.0 }
        return CGFloat(mode.pixelWidth) / bounds.width
    }

    func displayContaining(point: CGPoint) -> CGDirectDisplayID? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)

        for i in 0..<Int(count) {
            if CGDisplayBounds(displayIDs[i]).contains(point) {
                return displayIDs[i]
            }
        }
        return nil
    }
}
