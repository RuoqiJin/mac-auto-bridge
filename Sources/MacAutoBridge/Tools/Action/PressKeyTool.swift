import Foundation
import CoreGraphics

struct PressKeyTool: BridgeTool {

    static let name = "press_key"

    static let schema = ToolSchema(
        description: "Press a keyboard key with optional modifiers",
        properties: [
            "bundle_id": str("App bundle identifier for focus lock"),
            "key_code": int("CGKeyCode value"),
            "command": bool("Hold Command"),
            "shift": bool("Hold Shift"),
            "option": bool("Hold Option"),
            "control": bool("Hold Control"),
        ],
        required: ["bundle_id", "key_code"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let keyCode = UInt16(args["key_code"] as! Int)
        var flags: CGEventFlags = []
        if args["command"] as? Bool == true { flags.insert(.maskCommand) }
        if args["shift"] as? Bool == true { flags.insert(.maskShift) }
        if args["option"] as? Bool == true { flags.insert(.maskAlternate) }
        if args["control"] as? Bool == true { flags.insert(.maskControl) }

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        do {
            try await ctx.input.pressKey(keyCode: keyCode, flags: flags)
            await ctx.input.releaseFocus()
            return textResult("Pressed key \(keyCode)")
        } catch {
            await ctx.input.releaseFocus()
            throw error
        }
    }
}
