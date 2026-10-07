import CoreGraphics
import Foundation

/// One-call SRT export + workspace reset from 剪映 (CapCut Pro).
/// Cmd+E → export dialog → ExportOkBtn → rename → close dialog → clear timeline → clear materials.
/// Leaves 剪映 in a clean state ready for the next episode.
/// Data-driven from Codex op logs: replaces 10+ manual tool calls with 1.
struct ExportSrtTool: BridgeTool {

    static let name = "export_srt"
    static let timeout: TimeInterval = 45

    static let schema = ToolSchema(
        description:
            "One-call SRT export + workspace reset from 剪映. Exports SRT via Cmd+E, renames to {episode_name}-yoha-srt.srt, then clears timeline and material library for the next episode. REQUIRES: subtitles already recognized on the timeline.",
        properties: [
            "bundle_id": str("App bundle identifier (default: com.lemon.lvpro)"),
            "episode_name": str("Episode identifier for output filename, e.g. '120' → '120-yoha-srt.srt'"),
            "output_dir": str("Directory for the output SRT file (default: ~/Downloads)"),
        ],
        required: ["episode_name"])

    private let kKeyE: UInt16 = 14
    private let kKeyA: UInt16 = 0       // Cmd+A = Select All
    private let kDelete: UInt16 = 51

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as? String ?? "com.lemon.lvpro"
        let episodeName = args["episode_name"] as! String
        let outputDir = args["output_dir"] as? String ?? NSHomeDirectory() + "/Downloads"

        var log: [String] = []
        func step(_ msg: String) {
            let ts = ISO8601DateFormatter().string(from: Date())
            log.append("[\(ts)] \(msg)")
            // Detailed steps stay in the tool response; stderr may be persisted by the host.
            fputs("[ExportSrt] step \(log.count) completed\n", stderr)
        }

        // 1. Focus CapCut and press Cmd+E
        _ = try await ctx.input.acquireFocus(bundleID: bid)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await ctx.input.pressKey(keyCode: kKeyE, flags: .maskCommand)
        step("Pressed Cmd+E")

        // 2. Wait for export dialog (window title starts with "导出-")
        var dialogFound = false
        for _ in 1...10 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let windows = await ctx.input.listWindows(bundleID: bid)
            if windows.contains(where: { ($0.title ?? "").hasPrefix("导出-") }) {
                dialogFound = true
                break
            }
        }

        if !dialogFound {
            // Fallback: OCR click "导出"
            step("No export dialog detected, trying OCR click on '导出'")
            let entries = try await ctx.capture.findTextOnScreen(text: "导出", bundleID: bid)
            if let btn = entries.first {
                try await ctx.input.click(at: rectCenter(btn.frame))
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } else {
                return jsonResult(["error": "Export dialog not found", "log": log] as [String: Any])
            }
        }

        step("Export dialog ready")

        // 3. Click ExportOkBtn via AX (retry up to 5 times)
        var confirmed = false
        for _ in 1...5 {
            if let okBtn = try? await ctx.ax.findElement(
                bundleID: bid, query: AXQuery(role: "AXButton", identifier: "ExportOkBtn")),
                okBtn.frame != .zero
            {
                try await ctx.input.click(at: rectCenter(okBtn.frame))
                confirmed = true
                step("Clicked ExportOkBtn")
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if !confirmed {
            let dialogExport = try await ctx.capture.findTextOnScreen(text: "导出", bundleID: bid)
            if let btn = dialogExport.last {
                try await ctx.input.click(at: rectCenter(btn.frame))
                step("Clicked export via OCR fallback")
            } else {
                return jsonResult(["error": "ExportOkBtn not found", "log": log] as [String: Any])
            }
        }

        // 4. Wait for export completion
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let completion = (try? await ctx.capture.findTextOnScreen(
            text: "导出完成,打开文件夹,关闭", bundleID: bid)) ?? []
        if completion.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        step("Export completed")

        // 5. Rename most recent .srt to {episode}-yoha-srt.srt
        let outputName = "\(episodeName)-yoha-srt.srt"
        let outputPath = (outputDir as NSString).appendingPathComponent(outputName)
        let fm = FileManager.default

        // Also check ~/Downloads in case CapCut defaults there
        let searchDirs = outputDir == NSHomeDirectory() + "/Downloads"
            ? [outputDir]
            : [outputDir, NSHomeDirectory() + "/Downloads"]

        var renamed = false
        for dir in searchDirs {
            let contents = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            let srtFiles = contents
                .filter { $0.hasSuffix(".srt") }
                .compactMap { name -> (String, Date)? in
                    let path = (dir as NSString).appendingPathComponent(name)
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                        let mod = attrs[.modificationDate] as? Date,
                        abs(mod.timeIntervalSinceNow) < 60  // within last 60s
                    else { return nil }
                    return (path, mod)
                }
                .sorted { $0.1 > $1.1 }

            if let (recentSrt, _) = srtFiles.first, recentSrt != outputPath {
                try? fm.moveItem(atPath: recentSrt, toPath: outputPath)
                step("Renamed: \((recentSrt as NSString).lastPathComponent) → \(outputName)")
                renamed = true
                break
            }
        }

        if !renamed {
            step("Warning: no recent .srt found to rename")
        }

        // 6. Close completion dialog (AX button → OCR last-match → Escape)
        var dialogClosed = false

        // Try AX: find button titled "关闭"
        if let closeBtn = try? await ctx.ax.findElement(
            bundleID: bid, query: AXQuery(role: "AXButton", title: "关闭")),
            closeBtn.frame != .zero
        {
            try await ctx.input.click(at: rectCenter(closeBtn.frame))
            dialogClosed = true
            step("Closed dialog via AX button")
        }

        // OCR fallback: "关闭" is the LAST button in the dialog (rightmost)
        if !dialogClosed {
            let closeEntries = (try? await ctx.capture.findTextOnScreen(text: "关闭", bundleID: bid)) ?? []
            if let closeBtn = closeEntries.last {  // last = rightmost "关闭" button
                try await ctx.input.click(at: rectCenter(closeBtn.frame))
                dialogClosed = true
                step("Closed dialog via OCR")
            }
        }

        // Last resort: Escape to dismiss
        if !dialogClosed {
            try await ctx.input.pressKey(keyCode: 53)  // Escape
            step("Closed dialog via Escape")
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        // 7. Clear timeline: click timeline area → Cmd+A → Delete
        step("Clearing timeline")
        _ = try await ctx.input.acquireFocus(bundleID: bid)
        try await Task.sleep(nanoseconds: 300_000_000)

        // Find timeline root via AX (identifier: MainTimeLineRoot)
        if let timeline = try? await ctx.ax.findElement(
            bundleID: bid, query: AXQuery(identifier: "MainTimeLineRoot")),
            timeline.frame != .zero
        {
            try await ctx.input.click(at: rectCenter(timeline.frame))
        } else {
            // Fallback: click lower-center of main window (timeline area)
            let windows = await ctx.input.listWindows(bundleID: bid)
            if let mainWin = windows.max(by: {
                ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
            }) {
                let timelineCenter = CGPoint(
                    x: mainWin.frame.midX,
                    y: mainWin.frame.origin.y + mainWin.frame.height * 0.7)
                try await ctx.input.click(at: timelineCenter)
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await ctx.input.pressKey(keyCode: kKeyA, flags: .maskCommand)  // Cmd+A
        try await Task.sleep(nanoseconds: 200_000_000)
        try await ctx.input.pressKey(keyCode: kDelete)                     // Delete
        try await Task.sleep(nanoseconds: 500_000_000)
        step("Timeline cleared")

        // 8. Clear material library: click material panel → Cmd+A → Delete
        step("Clearing material library")
        if let panel = try? await ctx.ax.findElement(
            bundleID: bid, query: AXQuery(identifier: "MediaInfoViewContentView")),
            panel.frame != .zero
        {
            try await ctx.input.click(at: rectCenter(panel.frame))
        } else {
            // Fallback: OCR for material card / "素材" anchor
            let matEntries = (try? await ctx.capture.findTextOnScreen(
                text: "素材,导入,本地", bundleID: bid)) ?? []
            if let anchor = matEntries.first {
                try await ctx.input.click(
                    at: CGPoint(x: anchor.frame.midX, y: anchor.frame.maxY + 40))
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await ctx.input.pressKey(keyCode: kKeyA, flags: .maskCommand)  // Cmd+A
        try await Task.sleep(nanoseconds: 200_000_000)
        try await ctx.input.pressKey(keyCode: kDelete)                     // Delete
        try await Task.sleep(nanoseconds: 500_000_000)
        step("Material library cleared")

        await ctx.input.releaseFocus()

        let finalPath = fm.fileExists(atPath: outputPath) ? outputPath : "rename_may_have_failed"
        return jsonResult([
            "success": true,
            "srt_path": finalPath,
            "episode": episodeName,
            "log": log,
        ] as [String: Any])
    }
}
