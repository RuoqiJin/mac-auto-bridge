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

            let pid = info[kCGWindowOwnerPID as String] as? Int32
            let ownerBundle =
                pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }

            if let bid = bundleID, ownerBundle != bid { return nil }

            let frame = CGRect(
                x: bounds["X"] as? CGFloat ?? 0,
                y: bounds["Y"] as? CGFloat ?? 0,
                width: bounds["Width"] as? CGFloat ?? 0,
                height: bounds["Height"] as? CGFloat ?? 0
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
