import Foundation
import CoreGraphics

struct RightClickTool: BridgeTool {

    static let name = "right_click"

    static let schema = ToolSchema(
        description:
            "Right-click at a target to open a context menu. Supports OCR text or coordinates. Returns {clicked_at, menu_appeared, menu_items, menu_item_count} — `menu_appeared` is checked via Accessibility API after the click, so you do NOT need a screenshot to verify the right-click worked. If menu_appeared=false, the click missed; retry at a different point or use AX-locator.",
        properties: [
            "bundle_id": str("App bundle identifier for focus lock"),
            "target_text": str("Right-click on this text (found via OCR)"),
            "x": num("Right-click at X coordinate"),
            "y": num("Right-click at Y coordinate"),
            "nth": int("Which occurrence of target_text (default 1)"),
        ],
        required: ["bundle_id"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let nth = args["nth"] as? Int ?? 1

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        defer { Task { await ctx.input.releaseFocus() } }

        let point: CGPoint
        if let text = args["target_text"] as? String {
            let rect = try await LocatorEngine.shared.resolve(
                locator: .ocr(text), bundleID: bid, nth: nth)
            point = rectCenter(rect)
        } else {
            let x = args["x"] as? Double ?? 0
            let y = args["y"] as? Double ?? 0
            point = CGPoint(x: x, y: y)
        }
        try await ctx.input.click(at: point, button: .right)

        // Probe AX for a context menu so the agent doesn't need to screenshot
        // to verify the right-click landed. Wait up to ~400ms for menu to appear.
        var menuItems: [String] = []
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            menuItems = await ctx.ax.detectContextMenu(bundleID: bid)
            if !menuItems.isEmpty { break }
        }

        return jsonResult([
            "clicked_at": [Int(point.x), Int(point.y)] as [Int],
            "menu_appeared": !menuItems.isEmpty,
            "menu_items": menuItems,
            "menu_item_count": menuItems.count,
        ] as [String: Any])
    }
}
