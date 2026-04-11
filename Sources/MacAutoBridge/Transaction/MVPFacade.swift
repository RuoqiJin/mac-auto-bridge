@preconcurrency import AppKit
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

    // MARK: - High-Level Workflows

    /// Snapshot: one call returns window list + focused window AX tree (+ optional OCR).
    /// Default: windows + AX only (instant). Set includeOCR=true for text entries (slower).
    func snapshot(bundleID: String, includeOCR: Bool = false) async throws -> [String: Any] {
        let windows = focus.listWindows(bundleID: bundleID)
        let axTree: AXNode? = try? AXManager.shared.snapshotFocusedWindow(
            bundleID: bundleID, maxDepth: 3)

        var result: [String: Any] = [:]
        result["windows"] = windows.map { $0.toJSON() }
        result["window_count"] = windows.count

        if let ax = axTree {
            result["focused_window_ax"] = ax.toJSON()
        }

        if includeOCR {
            if let (image, entries) = try? await ocr.captureAndRecognize(
                bundleID: bundleID, fast: true)
            {
                result["ocr_width"] = image.width
                result["ocr_height"] = image.height
                result["ocr_entries"] = entries.map { $0.toJSON() }
                result["ocr_entry_count"] = entries.count
            }
        }

        return result
    }

    /// Navigate to a folder in a macOS file dialog (Open/Save panel).
    /// Sends Cmd+Shift+G → types path → presses Enter twice.
    func gotoFolder(bundleID: String, path: String) async throws -> Bool {
        _ = try await focus.acquire(bundleID: bundleID)
        defer { focus.release() }

        // Cmd+Shift+G = "Go to Folder" in macOS file dialogs
        try events.pressKey(keyCode: 5, flags: [.maskCommand, .maskShift])  // 5 = 'G'
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms for sheet to appear

        // Type the path
        try events.typeText(path)
        try await Task.sleep(nanoseconds: 300_000_000)  // 300ms for autocomplete

        // Press Enter to confirm path, then Enter again to navigate
        try events.pressKey(keyCode: 36)  // Return
        try await Task.sleep(nanoseconds: 500_000_000)

        // Verify via OCR that something related to the path appears
        let pathTail = (path as NSString).lastPathComponent
        if !pathTail.isEmpty {
            let entries = try await ocr.findTextOnScreen(text: pathTail, bundleID: bundleID)
            if entries.isEmpty {
                throw BridgeError.verificationFailed(
                    step: "goto_folder", detail: "'\(pathTail)' not found after navigation")
            }
        }

        return true
    }

    /// Scroll in a direction until target text appears (or max scrolls reached).
    /// Returns the found OCR entry on success. Throws on timeout.
    func scrollUntilText(
        bundleID: String, text: String, direction: String, maxScrolls: Int,
        scrollX: Double?, scrollY: Double?
    ) async throws -> [String: Any] {
        _ = try await focus.acquire(bundleID: bundleID)
        defer { focus.release() }

        let delta: Int32 = direction == "up" ? -80 : 80
        // Default scroll position: center of the largest window
        let windows = focus.listWindows(bundleID: bundleID)
        let scrollPoint: CGPoint
        if let x = scrollX, let y = scrollY {
            scrollPoint = CGPoint(x: x, y: y)
        } else if let main = windows.max(by: {
            ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
        }) {
            scrollPoint = CGPoint(x: main.frame.midX, y: main.frame.midY)
        } else {
            scrollPoint = .zero
        }

        for attempt in 1...maxScrolls {
            // Check if text is already visible
            let entries = try await ocr.findTextOnScreen(text: text, bundleID: bundleID)
            if !entries.isEmpty {
                return [
                    "found": true,
                    "attempts": attempt - 1,
                    "entries": entries.map { $0.toJSON() },
                ]
            }

            // Scroll and wait for UI update
            try events.scroll(at: scrollPoint, deltaY: delta)
            try await Task.sleep(nanoseconds: 400_000_000)  // 400ms between scrolls
        }

        // Final check after last scroll
        let entries = try await ocr.findTextOnScreen(text: text, bundleID: bundleID)
        if !entries.isEmpty {
            return [
                "found": true,
                "attempts": maxScrolls,
                "entries": entries.map { $0.toJSON() },
            ]
        }

        throw BridgeError.verificationFailed(
            step: "scroll_until_text",
            detail: "'\(text)' not found after \(maxScrolls) scrolls \(direction)")
    }
}
