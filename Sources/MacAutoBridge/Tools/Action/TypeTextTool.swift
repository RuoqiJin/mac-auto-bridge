import Foundation

struct TypeTextTool: BridgeTool {

    static let name = "type_text"

    static let schema = ToolSchema(
        description: "Type text into the focused application. Verifies focus before and during typing.",
        properties: [
            "bundle_id": str("App bundle identifier for focus lock"),
            "text": str("Text to type"),
            "verify_text": str("Optional: verify this text appears after typing"),
        ],
        required: ["bundle_id", "text"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let text = args["text"] as! String
        let verify = args["verify_text"] as? String

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        do {
            try await ctx.input.typeText(text)

            if let verify {
                try await Task.sleep(nanoseconds: 300_000_000)  // 300ms for UI update

                // Strategy 1: AX focused element value
                if let value = try? await ctx.ax.getFocusedElementValue(bundleID: bid),
                    value.contains(verify)
                {
                    await ctx.input.releaseFocus()
                    return textResult("Typed \(text.count) chars")
                }

                // Strategy 2: OCR fallback
                try await Task.sleep(nanoseconds: 200_000_000)
                let entries = try await ctx.capture.findTextOnScreen(
                    text: verify, bundleID: bid)
                guard !entries.isEmpty else {
                    await ctx.input.releaseFocus()
                    throw BridgeError.verificationFailed(
                        step: "type_text",
                        detail: "Text '\(verify)' not found after typing (checked AX value + OCR)")
                }
            }

            await ctx.input.releaseFocus()
            return textResult("Typed \(text.count) chars")
        } catch {
            await ctx.input.releaseFocus()
            throw error
        }
    }
}
