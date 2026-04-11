import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

final class OCRManager: @unchecked Sendable {

    static let shared = OCRManager()

    // MARK: - Capture + OCR

    func captureAndRecognize(bundleID: String, windowTitle: String? = nil) async throws -> (
        CGImage, [OCRTextEntry]
    ) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        guard
            let window = selectBestWindow(
                from: content.windows, bundleID: bundleID, windowTitle: windowTitle)
        else {
            throw BridgeError.elementNotFound("Window for \(bundleID)")
        }

        let windowFrame = window.frame
        let scale = displayScale(for: windowFrame)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(windowFrame.width * scale)
        config.height = Int(windowFrame.height * scale)
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        let rawEntries = try recognizeText(in: image)

        // Convert OCR pixel coords → screen-global coords
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

    func findTextOnScreen(text: String, bundleID: String? = nil) async throws -> [OCRTextEntry] {
        if let bid = bundleID {
            let (_, entries) = try await captureAndRecognize(bundleID: bid)
            return entries.filter { $0.text.localizedCaseInsensitiveContains(text) }
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

        return allEntries.filter { $0.text.localizedCaseInsensitiveContains(text) }
    }

    // MARK: - OCR Engine

    func recognizeText(in image: CGImage) throws -> [OCRTextEntry] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en"]
        request.usesLanguageCorrection = true

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
