@preconcurrency import AppKit
import CoreGraphics
import Foundation
import ImageIO

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

    /// Right-click target → wait for context menu → click menu item. One call replaces 3-4.
    func contextMenuClick(bundleID: String, targetText: String?, targetX: Double?, targetY: Double?,
                          menuItem: String, nth: Int = 1) async throws -> Bool {
        _ = try await focus.acquire(bundleID: bundleID)
        defer { focus.release() }

        // Step 1: Right-click on target
        let point: CGPoint
        if let text = targetText {
            let rect = try await locator.resolve(locator: .ocr(text), bundleID: bundleID, nth: nth)
            point = rectCenter(rect)
        } else if let x = targetX, let y = targetY {
            point = CGPoint(x: x, y: y)
        } else {
            throw BridgeError.elementNotFound("context_menu_click requires target_text or x/y")
        }
        try events.click(at: point, button: .right)

        // Step 2: Wait for context menu to appear
        try await Task.sleep(nanoseconds: 500_000_000)

        // Step 3: Click menu item — AX first (reliable), OCR fallback
        let query = AXQuery(role: "AXMenuItem", title: menuItem)
        if let node = try? AXManager.shared.findElement(bundleID: bundleID, query: query),
           node.frame != .zero {
            try events.click(at: rectCenter(node.frame))
            return true
        }

        // OCR fallback for non-standard menus
        try await Task.sleep(nanoseconds: 300_000_000)
        let entries = try await ocr.findTextOnScreen(text: menuItem, bundleID: bundleID)
        guard let entry = entries.first else {
            throw BridgeError.elementNotFound("Menu item '\(menuItem)' not found in context menu")
        }
        try events.click(at: rectCenter(entry.frame))
        return true
    }

    /// Watch screen for a progress indicator (e.g. "%") to disappear.
    /// Two-phase: first waits for the indicator to APPEAR, then waits for it to DISAPPEAR.
    ///
    /// **CRITICAL**: The Codex MCP client kills any tool call after 120s. This function
    /// caps internal blocking at 90s to stay safely below that. If the indicator is still
    /// visible at 90s, it returns `still_running: true` (NOT an error) so the caller knows
    /// to call again — never interpret a result with `still_running: true` as a failed task.
    func watchProgress(bundleID: String, disappears: String, timeout: TimeInterval) async throws
        -> [String: Any]
    {
        // Hard ceiling: stay well below Codex MCP 120s call timeout.
        let cappedTimeout = min(timeout, 90)
        let deadline = Date().addingTimeInterval(cappedTimeout)

        // Phase 1: Wait for indicator to APPEAR (max 12s of the budget, never more than half).
        let appearBudget = min(12, cappedTimeout / 2)
        let appearDeadline = Date().addingTimeInterval(appearBudget)
        var seen = false
        var lastSampleEmpty = false
        while Date() < appearDeadline {
            let entries = try await ocr.findTextOnScreen(text: disappears, bundleID: bundleID)
            if !entries.isEmpty {
                seen = true
                break
            }
            lastSampleEmpty = true
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Phase 2: Wait for indicator to DISAPPEAR.
        var consecutiveGone = 0
        var lastNonEmptyText: String? = nil
        while Date() < deadline {
            let entries = try await ocr.findTextOnScreen(text: disappears, bundleID: bundleID)
            if entries.isEmpty {
                consecutiveGone += 1
                if consecutiveGone >= 2 || (seen && consecutiveGone >= 1) {
                    var result = try await snapshot(bundleID: bundleID, includeOCR: true)
                    result["done"] = true
                    result["indicator_was_seen"] = seen
                    return result
                }
            } else {
                seen = true
                consecutiveGone = 0
                lastNonEmptyText = entries.first?.text
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Soft timeout: still in progress. Return state without throwing so the
        // caller doesn't misinterpret this as a failed task and re-trigger the action.
        var result: [String: Any] = [
            "still_running": true,
            "indicator_was_seen": seen,
            "elapsed_seconds": Int(cappedTimeout),
            "last_indicator_sample": lastNonEmptyText as Any,
            "phase": seen ? "waiting_for_disappear" : (lastSampleEmpty ? "never_appeared" : "appearing"),
            "advice": "Indicator still visible after \(Int(cappedTimeout))s. Call watch_progress again to keep waiting — DO NOT re-trigger the original action.",
        ]
        if let snap = try? await snapshot(bundleID: bundleID, includeOCR: false) {
            result["snapshot"] = snap
        }
        return result
    }

    /// Capture window screenshot and save to file. Returns the file path.
    /// For agents with image viewing capability (Codex view_image).
    func captureToFile(bundleID: String, windowTitle: String?, filePath: String?) async throws
        -> String
    {
        let image = try await ocr.captureOnly(bundleID: bundleID, windowTitle: windowTitle)

        let path = filePath ?? "/tmp/mac-auto-bridge-capture-\(Int(Date().timeIntervalSince1970)).png"
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw BridgeError.elementNotFound("Cannot create image file at \(path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BridgeError.elementNotFound("Failed to write image to \(path)")
        }
        return path
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
    /// Long search terms are auto-shortened (e.g. "pcea-talk-ep104-yoha.mp3" → "ep104").
    /// Returns the found OCR entry on success. Throws on timeout.
    func scrollUntilText(
        bundleID: String, text: String, direction: String, maxScrolls: Int,
        scrollX: Double?, scrollY: Double?
    ) async throws -> [String: Any] {
        _ = try await focus.acquire(bundleID: bundleID)
        defer { focus.release() }

        // Auto-shorten long search terms — OCR often breaks long filenames across lines
        let searchText = shortenForOCR(text)

        let delta: Int32 = direction == "up" ? -80 : 80
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
            let entries = try await ocr.findTextOnScreen(text: searchText, bundleID: bundleID)
            if !entries.isEmpty {
                return [
                    "found": true,
                    "attempts": attempt - 1,
                    "entries": entries.map { $0.toJSON() },
                ]
            }

            try events.scroll(at: scrollPoint, deltaY: delta)
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        // Final check after last scroll
        let entries = try await ocr.findTextOnScreen(text: searchText, bundleID: bundleID)
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

    // MARK: - Private Helpers

    /// Shorten long text for OCR matching. OCR often breaks long filenames across lines.
    /// "pcea-talk-ep104-yoha.mp3" → "ep104" (extract episode-like pattern)
    /// "some,keywords" → passed through (already multi-keyword)
    /// Short text (≤15 chars) → passed through unchanged
    private func shortenForOCR(_ text: String) -> String {
        // Already multi-keyword — pass through
        if text.contains(",") { return text }
        // Short enough for reliable OCR match
        if text.count <= 15 { return text }

        // Try to extract episode/number patterns like "ep104", "EP42", "ep181"
        let nsText = text as NSString
        let regex = try? NSRegularExpression(pattern: "[eE][pP]\\d+", options: [])
        if let match = regex?.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length))
        {
            return nsText.substring(with: match.range)
        }

        // Fallback: take the most distinctive segment (split by - . _ space, pick longest)
        let segments = text.components(separatedBy: CharacterSet(charactersIn: "-._/ "))
            .filter { $0.count >= 3 }
        if let best = segments.max(by: { $0.count < $1.count }), best.count <= 20 {
            return best
        }

        // Last resort: first 12 chars
        return String(text.prefix(12))
    }
}
