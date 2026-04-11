import CoreGraphics

final class LocatorEngine: @unchecked Sendable {

    static let shared = LocatorEngine()

    private let ax = AXManager.shared
    private let ocr = OCRManager.shared

    /// Resolve a TargetLocator to a screen-global CGRect.
    /// Strategy: AX first → OCR fallback → coordinate passthrough.
    func resolve(locator: TargetLocator, bundleID: String?, nth: Int = 1) async throws -> CGRect {
        switch locator {
        case .ax(let query):
            guard let bid = bundleID else {
                throw BridgeError.elementNotFound("bundle_id required for AX locator")
            }
            // Try AX
            if let node = try? ax.findElement(bundleID: bid, query: query),
                node.frame != .zero
            {
                return node.frame
            }
            // Fallback: use query.title as OCR text
            if let title = query.title {
                return try await resolveOCR(text: title, bundleID: bid, nth: nth)
            }
            throw BridgeError.elementNotFound(
                "AX query: role=\(query.role ?? "?") title=\(query.title ?? "?") id=\(query.identifier ?? "?")"
            )

        case .ocr(let text):
            return try await resolveOCR(text: text, bundleID: bundleID, nth: nth)

        case .coordinate(let point):
            return CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        }
    }

    private func resolveOCR(text: String, bundleID: String?, nth: Int) async throws -> CGRect {
        let entries = try await ocr.findTextOnScreen(text: text, bundleID: bundleID)
        guard entries.count >= nth else {
            throw BridgeError.elementNotFound(
                "OCR text '\(text)' (found \(entries.count), need #\(nth))")
        }
        return entries[nth - 1].frame
    }
}
