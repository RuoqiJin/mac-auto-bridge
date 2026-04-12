@preconcurrency import AppKit
import CoreGraphics

final class FocusManager: @unchecked Sendable {

    static let shared = FocusManager()

    private var lockedBundleID: String?
    private var lockedWindowTitle: String?

    // MARK: - Focus

    func focusApp(bundleID: String) async throws -> Bool {
        let app = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        } ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first

        guard let app else {
            throw BridgeError.appNotRunning(bundleID)
        }

        // Strategy 1: direct activation
        app.activate()

        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                return true
            }
        }

        // Strategy 2: AppleScript (more forceful — beats other apps holding focus)
        let script = NSAppleScript(source: "tell application id \"\(bundleID)\" to activate")
        script?.executeAndReturnError(nil)

        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                return true
            }
        }

        return false
    }

    func acquire(bundleID: String, expectedWindowTitle: String? = nil) async throws -> Bool {
        guard try await focusApp(bundleID: bundleID) else {
            throw BridgeError.focusLost(expected: bundleID, actual: currentBundleID())
        }

        if let title = expectedWindowTitle {
            // Strategy 1: AX focused window title
            if let window = try? AXManager.shared.snapshotFocusedWindow(bundleID: bundleID),
                let axTitle = window.title, axTitle.contains(title)
            {
                // AX title matches — good
            }
            // Strategy 2: CGWindowList title (fallback for system modals where AX title = nil)
            else if listWindows(bundleID: bundleID).contains(where: {
                $0.title?.contains(title) == true
            }) {
                // CGWindowList has a matching window — accept
            } else {
                let axTitle =
                    (try? AXManager.shared.snapshotFocusedWindow(bundleID: bundleID))?.title
                throw BridgeError.focusLost(
                    expected: "\(bundleID) / \(title)",
                    actual: "\(bundleID) / \(axTitle ?? "nil")")
            }
        }

        lockedBundleID = bundleID
        lockedWindowTitle = expectedWindowTitle
        return true
    }

    /// Always re-activate the locked app, regardless of current focus state.
    /// Called proactively before every event synthesis. No-op if no lock.
    /// Never throws — best-effort focus grab.
    func ensureActive() {
        guard let expected = lockedBundleID else { return }

        // Fast path: already frontmost
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expected {
            return
        }

        // Find and activate
        let app = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == expected
        } ?? NSRunningApplication.runningApplications(withBundleIdentifier: expected).first

        guard let app else { return }
        app.activate()

        // Brief wait for activation (max 200ms)
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.02)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expected {
                return
            }
        }
    }

    /// Verify focus before action. If drifted, try to re-acquire silently.
    /// Only throws if re-acquisition fails (target app no longer running).
    /// This makes action tools transparent to focus drift — agent doesn't need to manage focus.
    func verify() throws {
        guard let expected = lockedBundleID else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expected {
            return
        }

        // Focus drifted — try to re-acquire silently
        let app = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == expected
        } ?? NSRunningApplication.runningApplications(withBundleIdentifier: expected).first

        guard let app else {
            let actual = currentBundleID()
            release()
            throw BridgeError.focusLost(expected: expected, actual: actual)
        }

        app.activate()

        // Brief sync poll (sync because verify() is called from event synthesis)
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.05)  // 50ms × 20 = 1s max
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expected {
                return
            }
        }

        // Last resort: AppleScript activation
        let script = NSAppleScript(source: "tell application id \"\(expected)\" to activate")
        script?.executeAndReturnError(nil)

        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.05)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expected {
                return
            }
        }

        // Couldn't re-acquire — throw to prevent clicking wrong app
        let actual = currentBundleID()
        release()
        throw BridgeError.focusLost(expected: expected, actual: actual)
    }

    func release() {
        lockedBundleID = nil
        lockedWindowTitle = nil
    }

    // MARK: - Query

    func currentBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Window Listing

    private static let systemBundles: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.dock",
        "com.apple.SystemUIServer",
    ]

    func listWindows(bundleID: String?) -> [WindowInfo] {
        // Build PID→bundleID map from NSWorkspace (reliable for child processes)
        var pidMap: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier {
                pidMap[app.processIdentifier] = bid
            }
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else {
            fputs("[MacAutoBridge] CGWindowListCopyWindowInfo returned nil\n", stderr)
            return []
        }

        fputs(
            "[MacAutoBridge] CGWindowList raw: \(windowList.count), pidMap: \(pidMap.count) apps\n",
            stderr)

        return windowList.compactMap { info in
            guard let windowID = info[kCGWindowNumber as String] as? UInt32,
                let bounds = info[kCGWindowBounds as String] as? [String: Any]
            else { return nil }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let pid = info[kCGWindowOwnerPID as String] as? Int32

            // Resolve bundle ID: NSWorkspace map first, then per-process lookup
            let ownerBundle: String? =
                pid.flatMap { pidMap[$0] }
                ?? pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }

            // Filter: specific bundle requested
            if let bid = bundleID, ownerBundle != bid { return nil }

            let w = bounds["Width"] as? CGFloat ?? 0
            let h = bounds["Height"] as? CGFloat ?? 0

            // Filter: skip noise when listing all windows
            if bundleID == nil {
                if layer != 0 { return nil }
                if let ob = ownerBundle, Self.systemBundles.contains(ob) { return nil }
                if w < 50 || h < 50 { return nil }
            }

            let frame = CGRect(
                x: bounds["X"] as? CGFloat ?? 0,
                y: bounds["Y"] as? CGFloat ?? 0,
                width: w, height: h
            )

            return WindowInfo(
                windowID: windowID,
                title: info[kCGWindowName as String] as? String,
                bundleID: ownerBundle,
                frame: frame,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? true
            )
        }
    }
}
