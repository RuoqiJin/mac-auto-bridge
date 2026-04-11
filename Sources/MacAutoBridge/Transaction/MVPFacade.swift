import CoreGraphics
import Foundation

final class MVPFacade: @unchecked Sendable {

    static let shared = MVPFacade()

    private let focus = FocusManager.shared
    private let ocr = OCRManager.shared
    private let events = EventSynthesizer.shared
    private let locator = LocatorEngine.shared

    /// MVP #1 — Focus app and assert expected window title
    func focusAndAssert(bundleID: String, windowTitle: String?) async throws -> Bool {
        try await focus.acquire(bundleID: bundleID, expectedWindowTitle: windowTitle)
    }

    /// MVP #2 — Capture app window + OCR, returns text entries with screen-global coords
    func captureApp(bundleID: String) async throws -> (image: CGImage, entries: [OCRTextEntry]) {
        try await ocr.captureAndRecognize(bundleID: bundleID)
    }

    /// MVP #3 — Click on text found via OCR
    func clickText(bundleID: String, text: String, nth: Int = 1) async throws -> Bool {
        _ = try await focus.acquire(bundleID: bundleID)
        defer { focus.release() }

        let rect = try await locator.resolve(locator: .ocr(text), bundleID: bundleID, nth: nth)
        try events.click(at: rectCenter(rect))
        return true
    }

    /// MVP #4 — Type in focused field with optional post-verification.
    /// Verification strategy: AX value first (exact), OCR fallback (visual).
    func typeInFocusedField(bundleID: String, text: String, verifyText: String?) async throws
        -> Bool
    {
        _ = try await focus.acquire(bundleID: bundleID)
        defer { focus.release() }

        try events.typeText(text)

        if let verify = verifyText {
            try await Task.sleep(nanoseconds: 300_000_000)  // 300ms for UI update

            // Strategy 1: AX focused element value — most reliable, no false positives
            if let value = try? AXManager.shared.getFocusedElementValue(bundleID: bundleID),
                value.contains(verify)
            {
                return true
            }

            // Strategy 2: OCR fallback — for non-standard text fields (e.g. web views, canvas)
            try await Task.sleep(nanoseconds: 200_000_000)  // +200ms
            let entries = try await ocr.findTextOnScreen(text: verify, bundleID: bundleID)
            guard !entries.isEmpty else {
                throw BridgeError.verificationFailed(
                    step: "type_in_focused_field",
                    detail: "Text '\(verify)' not found after typing (checked AX value + OCR)")
            }
        }

        return true
    }
}
