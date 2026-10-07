import Foundation
import CoreGraphics

struct ScrollTool: BridgeTool {

    static let name = "scroll"

    static let schema = ToolSchema(
        description: "Scroll at a position. Positive delta_y = down, negative = up.",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "x": num("Scroll position X"),
            "y": num("Scroll position Y"),
            "delta_y": num("Scroll amount (positive=down, negative=up)"),
        ],
        required: ["bundle_id", "delta_y"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let x = args["x"] as? Double ?? 0
        let y = args["y"] as? Double ?? 0
        let deltaY = args["delta_y"] as! Double

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        do {
            try await ctx.input.scroll(at: CGPoint(x: x, y: y), deltaY: Int32(deltaY))
            await ctx.input.releaseFocus()
            return textResult("Scrolled \(deltaY)")
        } catch {
            await ctx.input.releaseFocus()
            throw error
        }
    }
}
