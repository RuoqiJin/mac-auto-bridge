import Foundation

struct SnapshotTool: BridgeTool {

    static let name = "snapshot"

    static let schema = ToolSchema(
        description:
            "All-in-one observation: returns window list + focused window AX tree (depth 3). Set include_ocr=true to also capture+OCR (slower). Default is fast mode without OCR.",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "include_ocr": bool("Include OCR text entries (slower, default false)"),
        ],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let includeOCR = args["include_ocr"] as? Bool ?? false
        return try await buildSnapshot(bundleID: bid, includeOCR: includeOCR, ctx: ctx)
    }

    /// Shared snapshot logic, callable from other tools (e.g. WatchProgressTool).
    static func buildSnapshot(
        bundleID: String, includeOCR: Bool, ctx: ToolContext
    ) async throws -> [String: Any] {
        let windows = await ctx.input.listWindows(bundleID: bundleID)
        let axTree: AXNode? = try? await ctx.ax.snapshotFocusedWindow(
            bundleID: bundleID, maxDepth: 3)

        var result: [String: Any] = [:]
        result["windows"] = windows.map { $0.toJSON() }
        result["window_count"] = windows.count

        if let ax = axTree {
            result["focused_window_ax"] = ax.toJSON()
        }

        if includeOCR {
            if let (image, entries) = try? await ctx.capture.captureAndRecognize(
                bundleID: bundleID, fast: true)
            {
                result["ocr_width"] = image.width
                result["ocr_height"] = image.height
                result["ocr_entries"] = entries.map { $0.toJSON() }
                result["ocr_entry_count"] = entries.count
            }
        }

        return result
    }
}

// Convenience for internal callers.
extension SnapshotTool {
    func buildSnapshot(
        bundleID: String, includeOCR: Bool, ctx: ToolContext
    ) async throws -> [String: Any] {
        try await Self.buildSnapshot(bundleID: bundleID, includeOCR: includeOCR, ctx: ctx)
    }
}
