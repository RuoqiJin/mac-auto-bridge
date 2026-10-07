import Foundation

struct GotoFolderTool: BridgeTool {

    static let name = "goto_folder"

    static let schema = ToolSchema(
        description:
            "Navigate to a folder in a macOS file dialog (Open/Save panel). Sends Cmd+Shift+G, types the path, and presses Enter. Verifies the folder name appears after navigation.",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "path": str("Absolute path to navigate to, e.g. /Users/me/Downloads"),
        ],
        required: ["bundle_id", "path"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let path = args["path"] as! String

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        defer { Task { await ctx.input.releaseFocus() } }

        // Cmd+Shift+G = "Go to Folder" in macOS file dialogs
        try await ctx.input.pressKey(
            keyCode: 5, flags: [.maskCommand, .maskShift])  // 5 = 'G'
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms for sheet to appear

        // Type the path
        try await ctx.input.typeText(path)
        try await Task.sleep(nanoseconds: 300_000_000)  // 300ms for autocomplete

        // Press Enter to confirm path
        try await ctx.input.pressKey(keyCode: 36)  // Return
        try await Task.sleep(nanoseconds: 500_000_000)

        // Verify via OCR that something related to the path appears
        let pathTail = (path as NSString).lastPathComponent
        if !pathTail.isEmpty {
            let entries = try await ctx.capture.findTextOnScreen(
                text: pathTail, bundleID: bid)
            if entries.isEmpty {
                throw BridgeError.verificationFailed(
                    step: "goto_folder",
                    detail: "'\(pathTail)' not found after navigation")
            }
        }

        return textResult("Navigated to \(path)")
    }
}
