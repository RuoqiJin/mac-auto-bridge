import Foundation
import CoreGraphics

struct ClickTextTool: BridgeTool {

    static let name = "click_text"

    static let schema = ToolSchema(
        description: "[MVP] Click on text found via OCR in the target app",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "text": str("Text to click on"),
            "nth": int("Which occurrence (default 1)"),
        ],
        required: ["bundle_id", "text"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let text = args["text"] as! String
        let nth = args["nth"] as? Int ?? 1

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        defer { Task { await ctx.input.releaseFocus() } }

        let rect = try await LocatorEngine.shared.resolve(
            locator: .ocr(text), bundleID: bid, nth: nth)
        try await ctx.input.click(at: rectCenter(rect))
        return textResult("Clicked text '\(text)'")
    }
}
