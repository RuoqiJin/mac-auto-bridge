import CoreGraphics
import Foundation

/// Bulkhead actor isolating CGEvent synthesis and focus management.
/// FocusManager and EventSynthesizer touch AppKit (NSWorkspace, NSRunningApplication)
/// which requires main-thread affinity. The underlying classes handle this internally.
actor InputGate {

    // Use .shared singletons — EventSynthesizer hardcodes FocusManager.shared
    // internally (ensureActive/verify). Backward compatible.
    private let focus = FocusManager.shared
    private let synth = EventSynthesizer.shared

    // MARK: - Focus

    func acquireFocus(
        bundleID: String,
        expectedWindowTitle: String? = nil
    ) async throws -> Bool {
        try await focus.acquire(bundleID: bundleID, expectedWindowTitle: expectedWindowTitle)
    }

    func releaseFocus() {
        focus.release()
    }

    func listWindows(bundleID: String? = nil) -> [WindowInfo] {
        focus.listWindows(bundleID: bundleID)
    }

    // MARK: - Mouse

    func click(at point: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) throws {
        try synth.click(at: point, clicks: clicks, button: button)
    }

    func drag(from start: CGPoint, to end: CGPoint) throws {
        try synth.drag(from: start, to: end)
    }

    func scroll(at point: CGPoint, deltaY: Int32) throws {
        try synth.scroll(at: point, deltaY: deltaY)
    }

    // MARK: - Keyboard

    func typeText(_ text: String) throws {
        try synth.typeText(text)
    }

    func pressKey(keyCode: UInt16, flags: CGEventFlags = []) throws {
        try synth.pressKey(keyCode: keyCode, flags: flags)
    }
}
