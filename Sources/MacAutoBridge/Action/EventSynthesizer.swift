import CoreGraphics
import Foundation

final class EventSynthesizer: @unchecked Sendable {

    static let shared = EventSynthesizer()

    private let focus = FocusManager.shared

    // MARK: - Mouse

    func click(at point: CGPoint, clicks: Int = 1, button: CGMouseButton = .left) throws {
        focus.ensureActive()
        try focus.verify()

        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        for i in 0..<clicks {
            guard
                let down = CGEvent(
                    mouseEventSource: nil, mouseType: downType,
                    mouseCursorPosition: point, mouseButton: button),
                let up = CGEvent(
                    mouseEventSource: nil, mouseType: upType,
                    mouseCursorPosition: point, mouseButton: button)
            else { continue }

            if clicks > 1 {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(i + 1))
                up.setIntegerValueField(.mouseEventClickState, value: Int64(i + 1))
            }

            down.post(tap: .cghidEventTap)
            usleep(20_000)
            up.post(tap: .cghidEventTap)

            if i < clicks - 1 { usleep(50_000) }
        }
    }

    func drag(from start: CGPoint, to end: CGPoint) throws {
        focus.ensureActive()
        try focus.verify()

        let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: start, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(50_000)

        let steps = 10
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            let drag = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDragged,
                mouseCursorPosition: p, mouseButton: .left)
            drag?.post(tap: .cghidEventTap)
            usleep(10_000)
        }

        let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: end, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
    }

    func scroll(at point: CGPoint, deltaY: Int32) throws {
        focus.ensureActive()
        try focus.verify()

        // Move cursor to position
        let move = CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        usleep(20_000)

        guard
            let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)
        else { return }
        scrollEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    func typeText(_ text: String) throws {
        focus.ensureActive()
        try focus.verify()

        let chars = Array(text.utf16)
        let chunkSize = 8

        for start in stride(from: 0, to: chars.count, by: chunkSize) {
            // Re-verify focus every 64 characters
            if start > 0 && start % 64 == 0 {
                try focus.verify()
            }

            let end = min(start + chunkSize, chars.count)
            var chunk = Array(chars[start..<end])

            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)

            usleep(10_000)
        }
    }

    func pressKey(keyCode: UInt16, flags: CGEventFlags = []) throws {
        focus.ensureActive()
        try focus.verify()

        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        usleep(20_000)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
