import Foundation

struct FocusAndAssertTool: BridgeTool {

    static let name = "focus_and_assert"

    static let schema = ToolSchema(
        description: "[MVP] Focus app and assert expected window title",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "expected_window_title": str("Expected window title"),
        ],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let title = args["expected_window_title"] as? String
        let ok = try await ctx.input.acquireFocus(
            bundleID: bid, expectedWindowTitle: title)
        return textResult("Focus verified", isError: !ok)
    }
}
