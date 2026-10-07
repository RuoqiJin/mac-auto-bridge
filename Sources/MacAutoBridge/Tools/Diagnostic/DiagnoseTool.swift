@preconcurrency import AppKit
import ApplicationServices
import Foundation

struct DiagnoseTool: BridgeTool {

    static let name = "diagnose"

    static let schema = ToolSchema(
        description:
            "Diagnose runtime environment: permissions, app visibility, window server access",
        properties: [:],
        required: [])

    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        var d: [String: Any] = [:]

        // Process identity
        d["pid"] = ProcessInfo.processInfo.processIdentifier
        d["parent_pid"] = getppid()
        d["process_name"] = ProcessInfo.processInfo.processName

        // NSWorkspace app visibility
        let allApps = NSWorkspace.shared.runningApplications
        d["nsworkspace_app_count"] = allApps.count
        d["nsworkspace_sample"] = allApps.prefix(5).map {
            [
                "bundle_id": $0.bundleIdentifier ?? "nil",
                "name": $0.localizedName ?? "nil",
                "pid": $0.processIdentifier,
            ] as [String: Any]
        }

        // NSRunningApplication direct API test (Finder is always running)
        let finderApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder")
        d["finder_via_nsrunning_count"] = finderApps.count

        // CGWindowList raw result
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let rawWindows =
            CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
        d["cgwindowlist_raw_count"] = rawWindows.count
        d["cgwindowlist_sample"] = rawWindows.prefix(3).map { w in
            [
                "owner_name": w[kCGWindowOwnerName as String] ?? "nil",
                "owner_pid": w[kCGWindowOwnerPID as String] ?? -1,
                "window_name": w[kCGWindowName as String] ?? "nil",
                "layer": w[kCGWindowLayer as String] ?? -1,
            ] as [String: Any]
        }

        // Accessibility permission
        d["ax_trusted"] = AXIsProcessTrusted()

        // Subsystem health from HealthMonitor
        let health = await ctx.health.status()
        var healthDict: [String: Any] = [:]
        switch health.ax {
        case .healthy:
            healthDict["ax"] = "healthy"
        case .degraded(let reason):
            healthDict["ax"] = "degraded"
            healthDict["ax_detail"] = reason
        case .dead:
            healthDict["ax"] = "dead"
        }
        if let blocker = health.systemBlocker {
            healthDict["system_blocker"] = blocker
        }
        d["subsystem_health"] = healthDict

        return jsonResult(d)
    }
}
