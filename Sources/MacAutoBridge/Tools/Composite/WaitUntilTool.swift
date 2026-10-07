import Foundation

struct WaitUntilTool: BridgeTool {

    static let name = "wait_until"

    static let schema = ToolSchema(
        description: "Wait until a condition is met (text appears/disappears, AX element, window)",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "text_appears": str("Wait for this text to appear on screen"),
            "text_disappears": str("Wait for this text to disappear"),
            "ax_role": str("Wait for AX element with this role"),
            "ax_title": str("Wait for AX element with this title"),
            "window_title": str("Wait for window with this title"),
            "timeout": num("Timeout in seconds (default 10)"),
        ],
        required: ["bundle_id"]
    )

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let timeout = args["timeout"] as? Double ?? 10.0

        let condition: VerificationCondition
        if let t = args["text_appears"] as? String {
            condition = .textAppears(t)
        } else if let t = args["text_disappears"] as? String {
            condition = .textDisappears(t)
        } else if let t = args["window_title"] as? String {
            condition = .windowAppears(t)
        } else if let t = args["ax_title"] as? String {
            condition = .axExists(AXQuery(role: args["ax_role"] as? String, title: t))
        } else {
            return textResult("No condition specified", isError: true)
        }

        try await TransactionRunner.shared.waitForCondition(
            condition, bundleID: bid, timeout: timeout)
        return textResult("Condition met")
    }
}
