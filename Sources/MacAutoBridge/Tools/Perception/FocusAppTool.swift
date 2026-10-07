import Foundation

struct FocusAppTool: BridgeTool {

    static let name = "focus_app"

    static let schema = ToolSchema(
        description: "Focus an application by bundle ID and optionally verify window title",
        properties: [
            "bundle_id": str("App bundle identifier, e.g. com.lemon.lvpro"),
            "expected_window_title": str("Optional: expected window title substring"),
        ],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let title = args["expected_window_title"] as? String
        let ok = try await ctx.input.acquireFocus(
            bundleID: bid, expectedWindowTitle: title)
        // focus_app intentionally keeps the lock — matching original ToolRegistry behavior
        // (mvp.focusAndAssert does not release)
        return textResult(
            "Focused \(bid)" + (title.map { ", verified window: \($0)" } ?? ""),
            isError: !ok)
    }
}
