import Foundation
import CoreGraphics
import ImageIO

struct LookTool: BridgeTool {

    static let name = "look"

    static let schema = ToolSchema(
        description:
            "PREFERRED 'see the screen' tool. Single call returns: PNG file path (pass to view_image), AX tree, and OCR entries. REPLACES the capture_to_file + snapshot(include_ocr=true) + view_image triple-call pattern — use this instead. Returns: file_path, image_width, image_height, ax_tree, ocr_entries (when include_ocr=true), ocr_count.",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "file_path": str(
                "Optional: output PNG path (default: /tmp/mac-auto-bridge-look-{ts}.png)"),
            "include_ocr": bool("Include OCR text entries (default true)"),
        ],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let filePath = args["file_path"] as? String
        let includeOCR = args["include_ocr"] as? Bool ?? true

        let started = Date()

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        defer { Task { await ctx.input.releaseFocus() } }

        let path = filePath
            ?? "/tmp/mac-auto-bridge-look-\(Int(Date().timeIntervalSince1970)).png"

        let image: CGImage
        var entries: [OCRTextEntry] = []
        var ocrTimedOut = false

        if includeOCR {
            // Try OCR path first. If it takes too long (serializer queue stall),
            // fall back to capture-only so the PNG is still delivered fast.
            do {
                let (img, ocrEntries) = try await withDeadline(
                    seconds: 8, step: "look_ocr"
                ) { [ctx] in
                    try await ctx.capture.captureAndRecognize(bundleID: bid, fast: true)
                }
                image = img
                entries = ocrEntries
            } catch {
                // OCR timed out — degrade to capture-only
                ocrTimedOut = true
                image = try await ctx.capture.captureOnly(bundleID: bid)
            }
        } else {
            image = try await ctx.capture.captureOnly(bundleID: bid)
        }

        // Write PNG
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

        var result: [String: Any] = [
            "file_path": path,
            "image_width": image.width,
            "image_height": image.height,
        ]

        // AX tree — cap at 2s so a busy app doesn't stall the whole response
        let axDeadline = Date().addingTimeInterval(2)
        if Date() < axDeadline,
            let ax = try? await ctx.ax.snapshotFocusedWindow(bundleID: bid, maxDepth: 4)
        {
            result["ax_tree"] = ax.toJSON()
        }

        if includeOCR && !ocrTimedOut {
            result["ocr_entries"] = entries.map { $0.toJSON() }
            result["ocr_count"] = entries.count
        }
        if ocrTimedOut {
            result["ocr_skipped"] = true
            result["ocr_skip_reason"] =
                "OCR timed out (serializer queue stall). PNG is still valid — use view_image. Re-call with include_ocr=false if you only need the screenshot."
        }

        let elapsed = Date().timeIntervalSince(started)
        result["duration_ms"] = Int(elapsed * 1000)
        return jsonResult(result)
    }
}
