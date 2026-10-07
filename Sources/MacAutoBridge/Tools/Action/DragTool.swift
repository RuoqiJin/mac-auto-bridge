import Foundation
import CoreGraphics

struct DragTool: BridgeTool {

    static let name = "drag"

    static let schema = ToolSchema(
        description: "Drag from one point to another (10-step interpolated). Use for timeline manipulation, moving items, etc.",
        properties: [
            "bundle_id": str("App bundle identifier for focus lock"),
            "from_x": num("Start X coordinate"),
            "from_y": num("Start Y coordinate"),
            "to_x": num("End X coordinate"),
            "to_y": num("End Y coordinate"),
        ],
        required: ["bundle_id", "from_x", "from_y", "to_x", "to_y"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let fromX = args["from_x"] as! Double
        let fromY = args["from_y"] as! Double
        let toX = args["to_x"] as! Double
        let toY = args["to_y"] as! Double

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        do {
            try await ctx.input.drag(
                from: CGPoint(x: fromX, y: fromY),
                to: CGPoint(x: toX, y: toY))
            await ctx.input.releaseFocus()
            return textResult(
                "Dragged (\(Int(fromX)),\(Int(fromY))) → (\(Int(toX)),\(Int(toY)))")
        } catch {
            await ctx.input.releaseFocus()
            throw error
        }
    }
}
