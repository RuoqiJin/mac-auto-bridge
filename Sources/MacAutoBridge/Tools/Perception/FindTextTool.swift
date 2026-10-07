import Foundation

struct FindTextTool: BridgeTool {

    static let name = "find_text_on_screen"

    static let schema = ToolSchema(
        description: "Find text on screen via OCR. Supports multiple comma-separated keywords (e.g. 'srt,字幕,subtitle') — matches ANY keyword. Returns all matching entries with coordinates.",
        properties: [
            "text": str("Text to search for. Comma-separated for multi-keyword: 'srt,字幕,export'"),
            "bundle_id": str("Optional: limit search to this app's windows"),
        ],
        required: ["text"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let text = args["text"] as! String
        let entries = try await ctx.capture.findTextOnScreen(
            text: text, bundleID: args["bundle_id"] as? String)
        return jsonResult(entries.map { $0.toJSON() })
    }
}
