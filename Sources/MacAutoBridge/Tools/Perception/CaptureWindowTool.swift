import Foundation
import CoreGraphics

struct CaptureWindowTool: BridgeTool {

    static let name = "capture_window"

    static let schema = ToolSchema(
        description: "Capture a window screenshot and run OCR, returns text entries with screen-global coordinates",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "window_title": str("Optional: window title substring"),
        ],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let title = args["window_title"] as? String
        let (image, entries) = try await ctx.capture.captureAndRecognize(
            bundleID: bid, windowTitle: title)
        return jsonResult([
            "width": image.width,
            "height": image.height,
            "text_entries": entries.map { $0.toJSON() },
        ] as [String: Any])
    }
}
