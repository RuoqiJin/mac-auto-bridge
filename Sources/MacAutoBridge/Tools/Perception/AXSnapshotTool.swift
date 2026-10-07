import Foundation

struct AXSnapshotTool: BridgeTool {

    static let name = "ax_snapshot"

    static let schema = ToolSchema(
        description: "Get the accessibility tree for an app's focused window",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "max_depth": int("Max tree depth (default 5)"),
        ],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let depth = args["max_depth"] as? Int ?? 5
        let tree = try await ctx.ax.snapshotFocusedWindow(bundleID: bid, maxDepth: depth)
        return jsonResult(tree.toJSON())
    }
}
