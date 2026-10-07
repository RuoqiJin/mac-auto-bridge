import Foundation

struct ListWindowsTool: BridgeTool {

    static let name = "list_windows"

    static let schema = ToolSchema(
        description: "List visible windows, optionally filtered by bundle ID",
        properties: ["bundle_id": str("Optional: filter by bundle identifier")],
        required: [])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let windows = await ctx.input.listWindows(bundleID: args["bundle_id"] as? String)
        return jsonResult(windows.map { $0.toJSON() })
    }
}
