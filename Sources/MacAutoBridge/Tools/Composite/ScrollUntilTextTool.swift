import Foundation
import CoreGraphics

struct ScrollUntilTextTool: BridgeTool {

    static let name = "scroll_until_text"

    static let schema = ToolSchema(
        description:
            "Scroll in a direction until target text appears on screen. Supports comma-separated keywords. Returns matched entries on success, throws on timeout.",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "text": str(
                "Text to find. Comma-separated for multi-keyword: 'srt,字幕,subtitle'"),
            "direction": str("Scroll direction: 'down' or 'up' (default 'down')"),
            "max_scrolls": int("Maximum scroll attempts (default 10)"),
            "scroll_x": num("Optional: X coordinate to scroll at"),
            "scroll_y": num("Optional: Y coordinate to scroll at"),
        ],
        required: ["bundle_id", "text"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let text = args["text"] as! String
        let direction = args["direction"] as? String ?? "down"
        let maxScrolls = args["max_scrolls"] as? Int ?? 10
        let scrollX = args["scroll_x"] as? Double
        let scrollY = args["scroll_y"] as? Double

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        defer { Task { await ctx.input.releaseFocus() } }

        // Auto-shorten long search terms — OCR often breaks long filenames across lines
        let searchText = Self.shortenForOCR(text)

        let delta: Int32 = direction == "up" ? -80 : 80
        let windows = await ctx.input.listWindows(bundleID: bid)
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
            let entries = try await ctx.capture.findTextOnScreen(
                text: searchText, bundleID: bid)
            if !entries.isEmpty {
                return jsonResult([
                    "found": true,
                    "attempts": attempt - 1,
                    "entries": entries.map { $0.toJSON() },
                ] as [String: Any])
            }

            try await ctx.input.scroll(at: scrollPoint, deltaY: delta)
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        // Final check after last scroll
        let entries = try await ctx.capture.findTextOnScreen(
            text: searchText, bundleID: bid)
        if !entries.isEmpty {
            return jsonResult([
                "found": true,
                "attempts": maxScrolls,
                "entries": entries.map { $0.toJSON() },
            ] as [String: Any])
        }

        throw BridgeError.verificationFailed(
            step: "scroll_until_text",
            detail: "'\(text)' not found after \(maxScrolls) scrolls \(direction)")
    }

    // MARK: - Private Helpers

    /// Shorten long text for OCR matching. OCR often breaks long filenames across lines.
    /// "podcast-ep104-sample.mp3" → "ep104" (extract episode-like pattern)
    /// "some,keywords" → passed through (already multi-keyword)
    /// Short text (≤15 chars) → passed through unchanged
    private static func shortenForOCR(_ text: String) -> String {
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
