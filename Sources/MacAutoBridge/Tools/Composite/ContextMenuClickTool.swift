import Foundation
import CoreGraphics

struct ContextMenuClickTool: BridgeTool {

    static let name = "context_menu_click"

    static let schema = ToolSchema(
        description:
            "Right-click on a target, wait for context menu, then click a menu item. Replaces the 3-step right_click → snapshot → click pattern. Target priority: AX query (~300ms, fastest) → OCR text (~1.5s) → raw x/y. PREFER target_ax_* params when the target is a known AX element — they are 5x faster than OCR.",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "target_ax_role": str("AX role of right-click target (preferred, fastest)"),
            "target_ax_title": str("AX title of right-click target"),
            "target_ax_id": str("AX identifier of right-click target"),
            "target_text": str("Right-click on this text (OCR fallback)"),
            "x": num("Right-click at X coordinate (last resort)"),
            "y": num("Right-click at Y coordinate (last resort)"),
            "menu_item": str("Menu item text to click, e.g. '识别字幕/歌词'"),
            "nth": int("Which occurrence of target_text (default 1)"),
        ],
        required: ["bundle_id", "menu_item"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let menuItem = args["menu_item"] as! String
        let nth = args["nth"] as? Int ?? 1
        let targetText = args["target_text"] as? String
        let targetX = args["x"] as? Double
        let targetY = args["y"] as? Double
        let targetAxRole = args["target_ax_role"] as? String
        let targetAxTitle = args["target_ax_title"] as? String
        let targetAxId = args["target_ax_id"] as? String

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        defer { Task { await ctx.input.releaseFocus() } }

        // Step 1: Resolve right-click point. AX first (cheapest), then OCR, then raw coords.
        let point: CGPoint
        if targetAxRole != nil || targetAxTitle != nil || targetAxId != nil {
            let q = AXQuery(
                role: targetAxRole, title: targetAxTitle, identifier: targetAxId)
            guard
                let node = try? await ctx.ax.findElement(bundleID: bid, query: q),
                node.frame != .zero
            else {
                throw BridgeError.elementNotFound(
                    "context_menu_click: AX target not found (role=\(targetAxRole ?? "*"), title=\(targetAxTitle ?? "*"), id=\(targetAxId ?? "*"))"
                )
            }
            point = rectCenter(node.frame)
        } else if let text = targetText {
            let rect = try await LocatorEngine.shared.resolve(
                locator: .ocr(text), bundleID: bid, nth: nth)
            point = rectCenter(rect)
        } else if let x = targetX, let y = targetY {
            point = CGPoint(x: x, y: y)
        } else {
            throw BridgeError.elementNotFound(
                "context_menu_click requires one of: target_ax_*, target_text, or x+y")
        }
        try await ctx.input.click(at: point, button: .right)

        // Step 2: Wait for context menu to appear
        try await Task.sleep(nanoseconds: 500_000_000)

        // Step 3: Click menu item — AX first (reliable), OCR fallback
        let query = AXQuery(role: "AXMenuItem", title: menuItem)
        if let node = try? await ctx.ax.findElement(bundleID: bid, query: query),
            node.frame != .zero
        {
            try await ctx.input.click(at: rectCenter(node.frame))
            return textResult("Context menu '\(menuItem)' clicked")
        }

        // OCR fallback for non-standard menus
        try await Task.sleep(nanoseconds: 300_000_000)
        let entries = try await ctx.capture.findTextOnScreen(text: menuItem, bundleID: bid)
        guard let entry = entries.first else {
            throw BridgeError.elementNotFound(
                "Menu item '\(menuItem)' not found in context menu")
        }
        try await ctx.input.click(at: rectCenter(entry.frame))
        return textResult("Context menu '\(menuItem)' clicked")
    }
}
