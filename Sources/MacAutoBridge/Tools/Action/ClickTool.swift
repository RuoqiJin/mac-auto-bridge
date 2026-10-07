import Foundation
import CoreGraphics

struct ClickTool: BridgeTool {

    static let name = "click"

    static let schema = ToolSchema(
        description: "Click at a target (OCR text / AX element / coordinates). Verifies focus before acting.",
        properties: [
            "bundle_id": str("App bundle identifier for focus lock"),
            "target_text": str("Click on this text (found via OCR)"),
            "target_x": num("Click at X coordinate"),
            "target_y": num("Click at Y coordinate"),
            "target_ax_role": str("AX element role"),
            "target_ax_title": str("AX element title"),
            "target_ax_id": str("AX element identifier"),
            "nth": int("Which occurrence to click (default 1)"),
            "clicks": int("Number of clicks (default 1)"),
        ],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let clicks = args["clicks"] as? Int ?? 1
        let nth = args["nth"] as? Int ?? 1
        let target = Self.resolveTarget(from: args)

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        do {
            let rect = try await LocatorEngine.shared.resolve(
                locator: target, bundleID: bid, nth: nth)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            try await ctx.input.click(at: center, clicks: clicks)
            await ctx.input.releaseFocus()
            return textResult("Clicked at (\(Int(center.x)), \(Int(center.y)))")
        } catch {
            await ctx.input.releaseFocus()
            throw error
        }
    }

    // MARK: - Private

    private static func resolveTarget(from args: [String: Any]) -> TargetLocator {
        if let text = args["target_text"] as? String { return .ocr(text) }
        if let x = args["target_x"] as? Double, let y = args["target_y"] as? Double {
            return .coordinate(CGPoint(x: x, y: y))
        }
        if args["target_ax_role"] != nil || args["target_ax_title"] != nil
            || args["target_ax_id"] != nil
        {
            return .ax(
                AXQuery(
                    role: args["target_ax_role"] as? String,
                    title: args["target_ax_title"] as? String,
                    identifier: args["target_ax_id"] as? String))
        }
        return .coordinate(.zero)
    }
}
