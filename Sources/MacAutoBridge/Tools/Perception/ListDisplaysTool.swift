import Foundation

struct ListDisplaysTool: BridgeTool {

    static let name = "list_displays"

    static let schema = ToolSchema(
        description: "List active displays with bounds and scale factors",
        properties: [:],
        required: [])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        jsonResult(DisplayManager.shared.listDisplays().map { $0.toJSON() })
    }
}
