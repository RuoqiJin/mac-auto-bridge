import Foundation
import CoreGraphics
import ImageIO

struct CaptureToFileTool: BridgeTool {

    static let name = "capture_to_file"

    static let schema = ToolSchema(
        description:
            "Capture a window screenshot and save as PNG file. Returns the file path. Use this when the agent has image viewing capability (e.g. Codex view_image) and needs to SEE the actual screen, not just OCR text.",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "window_title": str("Optional: window title substring"),
            "file_path": str(
                "Optional: output file path (default: /tmp/mac-auto-bridge-capture-{timestamp}.png)"),
        ],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let windowTitle = args["window_title"] as? String
        let filePath = args["file_path"] as? String

        let image = try await ctx.capture.captureOnly(
            bundleID: bid, windowTitle: windowTitle)

        let path = filePath
            ?? "/tmp/mac-auto-bridge-capture-\(Int(Date().timeIntervalSince1970)).png"
        let url = URL(fileURLWithPath: path)
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil)
        else {
            throw BridgeError.elementNotFound("Cannot create image file at \(path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BridgeError.elementNotFound("Failed to write image to \(path)")
        }
        return textResult("Saved to \(path)")
    }
}
