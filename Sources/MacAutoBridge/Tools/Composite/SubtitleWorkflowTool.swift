import CoreGraphics
import Foundation

/// Automated subtitle extraction workflow for 剪映 (CapCut Pro).
/// Single MCP call: drag MP3 to timeline → recognize subtitles → wait → export SRT → rename + cleanup.
/// Timeout: 600s (10 minutes) to accommodate long audio recognition.
///
/// Data-driven optimizations from Codex op logs (2026-04-12):
///   - Drag directly to timeline (skips material panel + right-click "新建时间线")
///   - `open -R` + AX selection for precise Finder drag source
///   - AX MainTimeLineRoot for timeline drop target
///   - Export + cleanup delegated to ExportSrtTool
///   - All findTextOnScreen wrapped (try?) — SCK single failure won't kill workflow
struct SubtitleWorkflowTool: BridgeTool {

    static let name = "subtitle_workflow"
    static let timeout: TimeInterval = 600

    static let schema = ToolSchema(
        description:
            "Automated subtitle extraction from MP3 in 剪映 (CapCut Pro). Single call: drag MP3 from Finder directly to timeline → recognize subtitles → wait → export SRT → rename → clear workspace. Returns output SRT path. Timeout: 10 minutes. REQUIRES: 剪映専業版 must be open.",
        properties: [
            "bundle_id": str("App bundle identifier (default: com.lemon.lvpro)"),
            "mp3_path": str("Absolute path to the MP3 file to process"),
            "output_dir": str("Directory for the output SRT file (default: same as mp3_path)"),
            "episode_name": str("Episode identifier for output filename, e.g. '120' → '120-yoha-srt.srt'"),
        ],
        required: ["mp3_path", "episode_name"])

    private let kEscapeKey: UInt16 = 53

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as? String ?? "com.lemon.lvpro"
        let mp3Path = args["mp3_path"] as! String
        let outputDir = args["output_dir"] as? String
            ?? (mp3Path as NSString).deletingLastPathComponent
        let episodeName = args["episode_name"] as! String
        let mp3Filename = (mp3Path as NSString).lastPathComponent
        let finderBid = "com.apple.finder"

        var log: [String] = []
        func step(_ msg: String) {
            let ts = ISO8601DateFormatter().string(from: Date())
            log.append("[\(ts)] \(msg)")
            // Detailed steps stay in the tool response; stderr may be persisted by the host.
            fputs("[SubtitleWorkflow] step \(log.count) completed\n", stderr)
        }

        step("Starting: \(mp3Filename) → \(episodeName)-yoha-srt.srt")

        var currentPhase = "init"
        do {
            return try await _run(
                bid: bid, mp3Path: mp3Path, outputDir: outputDir,
                episodeName: episodeName, mp3Filename: mp3Filename,
                finderBid: finderBid, ctx: ctx, step: step, log: &log,
                phase: &currentPhase)
        } catch {
            step("FAILED in \(currentPhase): \(error.localizedDescription)")
            return jsonResult([
                "error": error.localizedDescription,
                "phase": currentPhase,
                "log": log,
            ] as [String: Any])
        }
    }

    private func _run(
        bid: String, mp3Path: String, outputDir: String,
        episodeName: String, mp3Filename: String, finderBid: String,
        ctx: ToolContext, step: (String) -> Void, log: inout [String],
        phase: inout String
    ) async throws -> [String: Any] {

        // ── SCK Warm-up ──
        phase = "warmup"
        step("SCK warm-up capture")
        for attempt in 1...2 {
            do {
                _ = try await ctx.capture.captureOnly(bundleID: bid)
                break
            } catch {
                if attempt == 2 {
                    return jsonResult([
                        "error": "Screen capture unavailable after 2 attempts: \(error.localizedDescription). Check Screen Recording permission.",
                        "phase": "warmup",
                        "log": log,
                    ] as [String: Any])
                }
                step("SCK warm-up attempt \(attempt) failed, retrying in 2s...")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        // ── Phase 1: Drag MP3 from Finder directly to timeline ──
        phase = "phase1_drag_to_timeline"
        step("Phase 1: Drag MP3 to timeline")

        // 1a. Reveal and select file in Finder
        let revealProc = Process()
        revealProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        revealProc.arguments = ["-R", mp3Path]
        try revealProc.run()
        revealProc.waitUntilExit()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 1b. Get file position from Finder (AX selection → OCR → window center)
        _ = try await ctx.input.acquireFocus(bundleID: finderBid)
        try await Task.sleep(nanoseconds: 500_000_000)

        let filePos: CGPoint
        let selected = try? await ctx.ax.getSelection(bundleID: finderBid)
        if let sel = selected?.first, sel.frame != .zero {
            filePos = rectCenter(sel.frame)
            step("File position from AX selection: \(filePos)")
        } else {
            let shortName = shortenForOCR(mp3Filename)
            step("AX selection unavailable, OCR fallback: \(shortName)")
            let finderEntries = (try? await ctx.capture.findTextOnScreen(
                text: shortName, bundleID: finderBid)) ?? []
            if let entry = finderEntries.first {
                filePos = rectCenter(entry.frame)
            } else {
                let finderWindows = await ctx.input.listWindows(bundleID: finderBid)
                guard let fw = finderWindows.first(where: { $0.frame.width > 100 }) else {
                    throw BridgeError.elementNotFound("No Finder window available for drag source")
                }
                filePos = rectCenter(fw.frame)
                step("Using Finder window center: \(filePos)")
            }
        }

        // 1c. Find timeline drop target (AX MainTimeLineRoot → window estimate)
        _ = try await ctx.input.acquireFocus(bundleID: bid)
        try await Task.sleep(nanoseconds: 300_000_000)

        let dropTarget: CGPoint
        if let timeline = try? await ctx.ax.findElement(
            bundleID: bid, query: AXQuery(identifier: "MainTimeLineRoot")),
            timeline.frame != .zero
        {
            // Drop at left-center of timeline (near 00:00:00)
            dropTarget = CGPoint(
                x: timeline.frame.origin.x + timeline.frame.width * 0.15,
                y: timeline.frame.midY)
            step("Timeline drop target from AX: \(dropTarget)")
        } else {
            // Fallback: lower 60-70% of main window is the timeline area
            let windows = await ctx.input.listWindows(bundleID: bid)
            guard let mainWin = windows.max(by: {
                ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
            }) else {
                throw BridgeError.elementNotFound("Cannot find CapCut main window")
            }
            dropTarget = CGPoint(
                x: mainWin.frame.midX,
                y: mainWin.frame.origin.y + mainWin.frame.height * 0.65)
            step("Timeline drop target from window estimate: \(dropTarget)")
        }

        // 1d. Re-focus Finder and drag to timeline
        _ = try await ctx.input.acquireFocus(bundleID: finderBid)
        try await Task.sleep(nanoseconds: 200_000_000)

        step("Dragging from \(filePos) to \(dropTarget)")
        try await ctx.input.drag(from: filePos, to: dropTarget)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        _ = try await ctx.input.acquireFocus(bundleID: bid)
        try await Task.sleep(nanoseconds: 500_000_000)

        step("Phase 1 complete: MP3 on timeline")

        // ── Phase 2: Trigger subtitle recognition ──
        phase = "phase2_recognition"
        step("Phase 2: Triggering recognition")

        // Find clip on timeline by episode search key
        let searchKey = mp3Filename.contains("ep") ? "ep\(episodeName)" : shortenForOCR(mp3Filename)
        let clipEntries = (try? await ctx.capture.findTextOnScreen(
            text: searchKey, bundleID: bid)) ?? []

        if let clip = clipEntries.first {
            try await ctx.input.click(at: rectCenter(clip.frame), button: .right)
            try await Task.sleep(nanoseconds: 600_000_000)

            if let menuItem = try? await ctx.ax.findElement(
                bundleID: bid, query: AXQuery(role: "AXMenuItem", title: "识别字幕/歌词")),
                menuItem.frame != .zero
            {
                try await ctx.input.click(at: rectCenter(menuItem.frame))
            } else {
                try await ctx.input.pressKey(keyCode: kEscapeKey)
                throw BridgeError.elementNotFound("Menu item '识别字幕/歌词' not found")
            }
        } else {
            // Fallback: clip may not have OCR-visible text yet; right-click timeline center
            step("Clip text not found via OCR, right-clicking timeline center")
            try await ctx.input.click(at: dropTarget, button: .right)
            try await Task.sleep(nanoseconds: 600_000_000)

            if let menuItem = try? await ctx.ax.findElement(
                bundleID: bid, query: AXQuery(role: "AXMenuItem", title: "识别字幕/歌词")),
                menuItem.frame != .zero
            {
                try await ctx.input.click(at: rectCenter(menuItem.frame))
            } else {
                try await ctx.input.pressKey(keyCode: kEscapeKey)
                throw BridgeError.elementNotFound("Menu item '识别字幕/歌词' not found at timeline center")
            }
        }

        try await Task.sleep(nanoseconds: 2_000_000_000)
        step("Phase 2 complete: Recognition triggered")

        // ── Phase 3: Wait for recognition to complete ──
        phase = "phase3_wait"
        step("Phase 3: Waiting for recognition...")

        let maxWait: TimeInterval = 480
        let waitDeadline = Date().addingTimeInterval(maxWait)

        var percentSeen = false
        let appearDeadline = Date().addingTimeInterval(30)
        while Date() < appearDeadline {
            let entries = (try? await ctx.capture.findTextOnScreen(text: "%", bundleID: bid)) ?? []
            if !entries.isEmpty {
                percentSeen = true
                step("Recognition started (progress indicator visible)")
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        if !percentSeen {
            let check = (try? await ctx.capture.findTextOnScreen(
                text: "文本识别中", bundleID: bid)) ?? []
            if check.isEmpty {
                step("Recognition may have completed instantly or failed to start")
            }
        }

        var consecutiveGone = 0
        while Date() < waitDeadline {
            let entries = (try? await ctx.capture.findTextOnScreen(text: "%", bundleID: bid)) ?? []
            if entries.isEmpty {
                consecutiveGone += 1
                if (percentSeen && consecutiveGone >= 2) || (!percentSeen && consecutiveGone >= 4) {
                    step("Recognition complete (indicator gone)")
                    break
                }
            } else {
                percentSeen = true
                consecutiveGone = 0
                if let text = entries.first?.text {
                    step("Progress: \(text)")
                }
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }

        if Date() >= waitDeadline {
            return jsonResult([
                "error": "Recognition timed out after \(Int(maxWait))s",
                "phase": "phase3_wait",
                "log": log,
            ] as [String: Any])
        }

        try await Task.sleep(nanoseconds: 2_000_000_000)

        // ── Phase 4: Export SRT + rename + cleanup (delegated to ExportSrtTool) ──
        phase = "phase4_export"
        step("Phase 4: Delegating to export_srt")

        let exportResult = try await ExportSrtTool().execute(
            args: [
                "bundle_id": bid,
                "episode_name": episodeName,
                "output_dir": outputDir,
            ] as [String: Any],
            ctx: ctx)

        // Merge export logs
        if let resultText = (exportResult["content"] as? [[String: Any]])?.first?["text"] as? String,
            let resultData = resultText.data(using: .utf8),
            let resultDict = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        {
            if let exportLog = resultDict["log"] as? [String] {
                log.append(contentsOf: exportLog)
            }
            if let error = resultDict["error"] as? String {
                return jsonResult([
                    "error": error,
                    "phase": "phase4_export",
                    "log": log,
                ] as [String: Any])
            }

            step("Done!")

            let srtPath = resultDict["srt_path"] as? String ?? "unknown"
            return jsonResult([
                "success": true,
                "srt_path": srtPath,
                "episode": episodeName,
                "mp3": mp3Filename,
                "log": log,
            ] as [String: Any])
        }

        step("Done! (export result unparseable)")
        return exportResult
    }
}
