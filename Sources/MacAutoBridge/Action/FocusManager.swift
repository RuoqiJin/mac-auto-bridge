@preconcurrency import AppKit
import CoreGraphics

final class FocusManager: @unchecked Sendable {

    static let shared = FocusManager()

    private var lockedBundleID: String?
    private var lockedWindowTitle: String?

    // MARK: - Focus

    func focusApp(bundleID: String) async throws -> Bool {
        guard
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else {
            throw BridgeError.appNotRunning(bundleID)
        }
        app.activate()

        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
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
            if let window = try? AXManager.shared.snapshotFocusedWindow(bundleID: bundleID) {
                guard window.title?.contains(title) == true else {
                    throw BridgeError.focusLost(
                        expected: "\(bundleID) / \(title)",
                        actual: "\(bundleID) / \(window.title ?? "nil")")
                }
            }
        }

        lockedBundleID = bundleID
        lockedWindowTitle = expectedWindowTitle
        return true
    }

    func verify() throws {
        guard let expected = lockedBundleID else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expected else {
            let actual = currentBundleID()
            release()
            throw BridgeError.focusLost(expected: expected, actual: actual)
        }
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
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        return windowList.compactMap { info in
            guard let windowID = info[kCGWindowNumber as String] as? UInt32,
                let bounds = info[kCGWindowBounds as String] as? [String: Any]
            else { return nil }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let pid = info[kCGWindowOwnerPID as String] as? Int32
            let ownerBundle =
                pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }

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
