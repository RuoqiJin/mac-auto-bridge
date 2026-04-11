import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

final class OCRManager: @unchecked Sendable {

    static let shared = OCRManager()

    // MARK: - Capture + OCR

    func captureAndRecognize(bundleID: String, windowTitle: String? = nil, fast: Bool = false)
        async throws -> (CGImage, [OCRTextEntry])
    {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        // If windowTitle specified → single window capture (precise)
        if windowTitle != nil {
            guard
                let window = selectBestWindow(
                    from: content.windows, bundleID: bundleID, windowTitle: windowTitle)
            else {
                throw BridgeError.elementNotFound("Window '\(windowTitle!)' for \(bundleID)")
            }
            return try await captureSingleWindow(window: window, fast: fast)
        }

        // Default: capture ALL windows from this app (includes popups, dialogs, menus)
        guard let app = content.applications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else {
            throw BridgeError.elementNotFound("App not found: \(bundleID)")
        }

        let appWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID
                && $0.isOnScreen && $0.frame.width > 10 && $0.frame.height > 10
        }
        guard !appWindows.isEmpty else {
            throw BridgeError.elementNotFound("No visible windows for \(bundleID)")
        }

        // Compute bounding box of all app windows
        var unionRect = appWindows[0].frame
        for w in appWindows.dropFirst() {
            unionRect = unionRect.union(w.frame)
        }

        // Find display containing the main window
        let center = CGPoint(x: unionRect.midX, y: unionRect.midY)
        guard let displayID = DisplayManager.shared.displayContaining(point: center),
            let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            // Fallback: single window capture
            let fallback = selectBestWindow(
                from: content.windows, bundleID: bundleID, windowTitle: nil)!
            return try await captureSingleWindow(window: fallback, fast: fast)
        }

        let scale = DisplayManager.shared.scaleFor(display: displayID)
        let displayBounds = CGDisplayBounds(displayID)

        // Convert union rect from screen-global to display-local coordinates
        let sourceRect = CGRect(
            x: unionRect.origin.x - displayBounds.origin.x,
            y: unionRect.origin.y - displayBounds.origin.y,
            width: unionRect.width,
            height: unionRect.height
        )

        let filter = SCContentFilter(
            display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(unionRect.width * scale)
        config.height = Int(unionRect.height * scale)
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        let rawEntries = try recognizeText(in: image, fast: fast)

        // Convert OCR pixel coords → screen-global coords (relative to unionRect origin)
        let screenEntries = rawEntries.map { entry in
            OCRTextEntry(
                text: entry.text,
                frame: CGRect(
                    x: unionRect.origin.x + entry.frame.origin.x / scale,
                    y: unionRect.origin.y + entry.frame.origin.y / scale,
                    width: entry.frame.width / scale,
                    height: entry.frame.height / scale
                ),
                confidence: entry.confidence
            )
        }

        return (image, screenEntries)
    }

    /// Capture only — NO OCR at all. For capture_to_file where we just need the image.
    func captureOnly(bundleID: String, windowTitle: String? = nil) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        if let title = windowTitle {
            guard let window = selectBestWindow(
                from: content.windows, bundleID: bundleID, windowTitle: title)
            else {
                throw BridgeError.elementNotFound("Window '\(title)' for \(bundleID)")
            }
            let scale = displayScale(for: window.frame)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        }

        // App-level capture (includes popups/menus)
        guard let app = content.applications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else {
            throw BridgeError.elementNotFound("App not found: \(bundleID)")
        }

        let appWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID
                && $0.isOnScreen && $0.frame.width > 10 && $0.frame.height > 10
        }
        guard !appWindows.isEmpty else {
            throw BridgeError.elementNotFound("No visible windows for \(bundleID)")
        }

        var unionRect = appWindows[0].frame
        for w in appWindows.dropFirst() { unionRect = unionRect.union(w.frame) }

        let center = CGPoint(x: unionRect.midX, y: unionRect.midY)
        guard let displayID = DisplayManager.shared.displayContaining(point: center),
            let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            // Fallback: single largest window
            let w = appWindows.max(by: {
                ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
            })!
            let scale = displayScale(for: w.frame)
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let config = SCStreamConfiguration()
            config.width = Int(w.frame.width * scale)
            config.height = Int(w.frame.height * scale)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        }

        let scale = DisplayManager.shared.scaleFor(display: displayID)
        let displayBounds = CGDisplayBounds(displayID)
        let sourceRect = CGRect(
            x: unionRect.origin.x - displayBounds.origin.x,
            y: unionRect.origin.y - displayBounds.origin.y,
            width: unionRect.width, height: unionRect.height)

        let filter = SCContentFilter(
            display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(unionRect.width * scale)
        config.height = Int(unionRect.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
    }

    /// Single window capture (original behavior — for targeted window_title queries)
    private func captureSingleWindow(window: SCWindow, fast: Bool) async throws -> (
        CGImage, [OCRTextEntry]
    ) {
        let windowFrame = window.frame
        let scale = displayScale(for: windowFrame)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(windowFrame.width * scale)
        config.height = Int(windowFrame.height * scale)
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        let rawEntries = try recognizeText(in: image, fast: fast)

        let screenEntries = rawEntries.map { entry in
            OCRTextEntry(
                text: entry.text,
                frame: CGRect(
                    x: windowFrame.origin.x + entry.frame.origin.x / scale,
                    y: windowFrame.origin.y + entry.frame.origin.y / scale,
                    width: entry.frame.width / scale,
                    height: entry.frame.height / scale
                ),
                confidence: entry.confidence
            )
        }

        return (image, screenEntries)
    }

    /// Search for one or more keywords. Pass comma-separated terms to match any.
    func findTextOnScreen(text: String, bundleID: String? = nil) async throws -> [OCRTextEntry] {
        let keywords = text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        if let bid = bundleID {
            let (_, entries) = try await captureAndRecognize(bundleID: bid)
            return entries.filter { entry in
                keywords.contains { entry.text.localizedCaseInsensitiveContains($0) }
            }
        }

        // Scan ALL displays — critical for multi-monitor setups
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else {
            throw BridgeError.screenCaptureDenied
        }

        var allEntries: [OCRTextEntry] = []

        for display in content.displays {
            let scale = DisplayManager.shared.scaleFor(display: display.displayID)
            let displayBounds = CGDisplayBounds(display.displayID)

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * Int(scale)
            config.height = display.height * Int(scale)
            config.showsCursor = false

            guard
                let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
            else { continue }

            let rawEntries = (try? recognizeText(in: image)) ?? []

            let screenEntries = rawEntries.map { entry in
                OCRTextEntry(
                    text: entry.text,
                    frame: CGRect(
                        x: displayBounds.origin.x + entry.frame.origin.x / scale,
                        y: displayBounds.origin.y + entry.frame.origin.y / scale,
                        width: entry.frame.width / scale,
                        height: entry.frame.height / scale
                    ),
                    confidence: entry.confidence
                )
            }
            allEntries.append(contentsOf: screenEntries)
        }

        return allEntries.filter { entry in
            keywords.contains { entry.text.localizedCaseInsensitiveContains($0) }
        }
    }

    // MARK: - OCR Engine

    func recognizeText(in image: CGImage, fast: Bool = false) throws -> [OCRTextEntry] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let bb = observation.boundingBox
            // Vision: normalized coords, origin bottom-left → pixel coords, origin top-left
            let rect = CGRect(
                x: bb.origin.x * imageWidth,
                y: (1 - bb.origin.y - bb.height) * imageHeight,
                width: bb.width * imageWidth,
                height: bb.height * imageHeight
            )
            return OCRTextEntry(text: candidate.string, frame: rect, confidence: candidate.confidence)
        }
    }

    // MARK: - Private

    private func displayScale(for windowFrame: CGRect) -> CGFloat {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let displayID = DisplayManager.shared.displayContaining(point: center) {
            return DisplayManager.shared.scaleFor(display: displayID)
        }
        return 2.0
    }

    /// Rank windows: title match > largest area. Filters out non-normal layers and tiny windows.
    private func selectBestWindow(
        from windows: [SCWindow], bundleID: String, windowTitle: String?
    ) -> SCWindow? {
        let candidates = windows.filter { w in
            guard w.owningApplication?.bundleIdentifier == bundleID else { return false }
            guard w.isOnScreen else { return false }
            guard w.windowLayer == 0 else { return false }
            guard w.frame.width > 50 && w.frame.height > 50 else { return false }
            return true
        }

        // Title match takes priority
        if let title = windowTitle,
            let match = candidates.first(where: { $0.title?.contains(title) == true })
        {
            return match
        }

        // Largest on-screen window = main window
        return candidates.max(by: {
            ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
        })
    }
}
