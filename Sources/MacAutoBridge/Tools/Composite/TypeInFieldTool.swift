import Foundation

struct TypeInFieldTool: BridgeTool {

    static let name = "type_in_focused_field"

    static let schema = ToolSchema(
        description: "[MVP] Type text into the focused field with optional verification",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "text": str("Text to type"),
            "verify_text": str("Optional: verify this text appears after typing"),
        ],
        required: ["bundle_id", "text"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let text = args["text"] as! String
        let verify = args["verify_text"] as? String

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        defer { Task { await ctx.input.releaseFocus() } }

        try await ctx.input.typeText(text)

        if let verify {
            try await Task.sleep(nanoseconds: 300_000_000)  // 300ms for UI update

            // Strategy 1: AX focused element value — most reliable, no false positives
            if let value = try? await ctx.ax.getFocusedElementValue(bundleID: bid),
                value.contains(verify)
            {
                return textResult("Typed \(text.count) chars")
            }

            // Strategy 2: OCR fallback — for non-standard text fields (e.g. web views, canvas)
            try await Task.sleep(nanoseconds: 200_000_000)  // +200ms
            let entries = try await ctx.capture.findTextOnScreen(text: verify, bundleID: bid)
            guard !entries.isEmpty else {
                throw BridgeError.verificationFailed(
                    step: "type_in_focused_field",
                    detail: "Text '\(verify)' not found after typing (checked AX value + OCR)")
            }
        }

        return textResult("Typed \(text.count) chars")
    }
}
