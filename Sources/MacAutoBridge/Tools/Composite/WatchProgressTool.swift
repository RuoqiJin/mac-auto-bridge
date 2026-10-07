import Foundation

struct WatchProgressTool: BridgeTool {

    static let name = "watch_progress"

    static let schema = ToolSchema(
        description:
            "Watch screen until a progress indicator disappears (e.g. '%' during subtitle recognition). Polls OCR every 2 seconds, caps at 110s (below Codex MCP 120s kill). Result: `done:true` = finished, act now. `still_running:true` = NOT finished, progress may look frozen but this is NORMAL — subtitle recognition routinely stays at the same percentage (e.g. '45%') for 30-60 seconds during heavy processing. ALWAYS call watch_progress again. NEVER cancel or re-trigger the original action based on still_running alone.",
        properties: [
            "bundle_id": str("App bundle identifier"),
            "disappears": str("Text that should disappear, e.g. '%' for progress bars"),
            "timeout": num("Max wait time in seconds (default 110, hard cap 110)"),
        ],
        required: ["bundle_id", "disappears"])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        let bid = args["bundle_id"] as! String
        let disappears = args["disappears"] as! String
        let timeout = args["timeout"] as? Double ?? 120.0

        // Hard ceiling: stay well below Codex MCP 120s call timeout (10s buffer).
        let cappedTimeout = min(timeout, 110)
        let deadline = Date().addingTimeInterval(cappedTimeout)

        // Phase 1: Wait for indicator to APPEAR.
        // Budget: up to 30s or half the timeout, whichever is smaller.
        // The old 12s was too short — accurate-mode OCR takes ~800ms/scan,
        // and subtitle recognition can take 3-5s to show the first "%".
        let appearBudget = min(30, cappedTimeout / 2)
        let appearDeadline = Date().addingTimeInterval(appearBudget)
        var seen = false
        while Date() < appearDeadline {
            let entries = try await ctx.capture.findTextOnScreen(
                text: disappears, bundleID: bid)
            if !entries.isEmpty {
                seen = true
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Phase 2: Wait for indicator to DISAPPEAR.
        // Key rule: require 3 consecutive "gone" checks UNLESS we already
        // saw the indicator in Phase 1 (then 2 is enough).
        // The old code used `consecutiveGone >= 2` even when `seen = false`,
        // causing false "done" in 4.5s when the indicator hadn't appeared yet.
        let requiredGoneChecks = seen ? 2 : 3
        var consecutiveGone = 0
        var lastNonEmptyText: String? = nil
        while Date() < deadline {
            let entries = try await ctx.capture.findTextOnScreen(
                text: disappears, bundleID: bid)
            if entries.isEmpty {
                consecutiveGone += 1
                if seen && consecutiveGone >= requiredGoneChecks {
                    // Confirmed: indicator appeared then disappeared.
                    var result = try await SnapshotTool.buildSnapshot(
                        bundleID: bid, includeOCR: true, ctx: ctx)
                    result["done"] = true
                    result["indicator_was_seen"] = true
                    return jsonResult(result)
                }
                // If we never saw the indicator and got 3 consecutive empty scans
                // after 30s of Phase 1 waiting, it likely means the task completed
                // before we started watching, or it was never triggered.
                // Return "never_appeared" so the agent can investigate, NOT "done".
                if !seen && consecutiveGone >= requiredGoneChecks {
                    var result: [String: Any] = [
                        "never_appeared": true,
                        "elapsed_seconds": Int(-deadline.timeIntervalSinceNow + cappedTimeout),
                        "advice": "Indicator '\(disappears)' was never seen after \(Int(appearBudget))s. The task may not have started, or it completed instantly. Check the screen state before calling watch_progress again.",
                    ]
                    if let snap = try? await SnapshotTool.buildSnapshot(
                        bundleID: bid, includeOCR: true, ctx: ctx)
                    {
                        result["snapshot"] = snap
                    }
                    return jsonResult(result)
                }
            } else {
                seen = true
                consecutiveGone = 0
                lastNonEmptyText = entries.first?.text
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Soft timeout: indicator still visible after full budget.
        var result: [String: Any] = [
            "still_running": true,
            "indicator_was_seen": seen,
            "elapsed_seconds": Int(cappedTimeout),
            "last_indicator_sample": lastNonEmptyText as Any,
            "phase": seen
                ? "waiting_for_disappear"
                : "never_appeared",
            "advice":
                "Progress still running after \(Int(cappedTimeout))s. This is NORMAL for long tasks (e.g. subtitle recognition can stay at the same % for 30-60s). Call watch_progress again to keep waiting. DO NOT cancel or re-trigger the original action.",
        ]
        if let snap = try? await SnapshotTool.buildSnapshot(
            bundleID: bid, includeOCR: false, ctx: ctx)
        {
            result["snapshot"] = snap
        }
        return jsonResult(result)
    }
}
