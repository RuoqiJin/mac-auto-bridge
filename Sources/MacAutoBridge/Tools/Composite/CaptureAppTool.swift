import Foundation
import CoreGraphics

struct CaptureAppTool: BridgeTool {

    static let name = "capture_app"

    static let schema = ToolSchema(
        description: "[MVP] Capture app window + OCR, returns text entries with coordinates",
        properties: ["bundle_id": str("App bundle identifier")],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let (image, entries) = try await ctx.capture.captureAndRecognize(bundleID: bid)
        return jsonResult([
            "width": image.width,
            "height": image.height,
            "entry_count": entries.count,
            "text_entries": entries.map { $0.toJSON() },
        ] as [String: Any])
    }
}
