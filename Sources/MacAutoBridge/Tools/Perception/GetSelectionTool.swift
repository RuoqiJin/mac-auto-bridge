import Foundation

struct GetSelectionTool: BridgeTool {

    static let name = "get_selection"

    static let schema = ToolSchema(
        description: "Read which elements are currently SELECTED in the focused window via Accessibility API. Use this INSTEAD of squinting at a screenshot to decide whether items are selected — works for timeline clips, list rows, table cells, multi-selection, etc. Returns selected elements with role/title/frame.",
        properties: ["bundle_id": str("App bundle identifier")],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let selected = try await ctx.ax.getSelection(bundleID: bid)
        return jsonResult([
            "count": selected.count,
            "selected": selected.map { $0.toJSON() },
        ] as [String: Any])
    }
}
