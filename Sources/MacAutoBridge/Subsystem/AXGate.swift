import ApplicationServices
import AppKit

/// Bulkhead actor isolating all Accessibility API calls.
/// If the AX subsystem hangs, capture and input gates remain operational.
actor AXGate {

    enum Health: Sendable {
        case healthy
        case degraded(String)
        case dead
    }

    private let ax = AXManager()

    // MARK: - Snapshot

    func snapshotFocusedWindow(bundleID: String, maxDepth: Int = 5) async throws -> AXNode {
        try await withDeadline(seconds: 5, step: "ax_gate.snapshotFocusedWindow") { [ax] in
            try ax.snapshotFocusedWindow(bundleID: bundleID, maxDepth: maxDepth)
        }
    }

    // MARK: - Find

    func findElement(bundleID: String, query: AXQuery) throws -> AXNode? {
        try ax.findElement(bundleID: bundleID, query: query)
    }

    func findElements(bundleID: String, query: AXQuery) throws -> [AXNode] {
        try ax.findElements(bundleID: bundleID, query: query)
    }

    // MARK: - Actions

    func performAction(bundleID: String, query: AXQuery, action: String = "AXPress") throws {
        let success = try ax.performAction(bundleID: bundleID, query: query, action: action)
        if !success {
            throw BridgeError.elementNotFound("AX action '\(action)' failed for query")
        }
    }

    // MARK: - Value / Selection

    func getFocusedElementValue(bundleID: String) throws -> String? {
        try ax.getFocusedElementValue(bundleID: bundleID)
    }

    func getSelection(bundleID: String) throws -> [AXNode] {
        try ax.getSelection(bundleID: bundleID)
    }

    // MARK: - Context Menu

    func detectContextMenu(bundleID: String) -> [String] {
        ax.detectContextMenu(bundleID: bundleID)
    }

    // MARK: - Health Probe

    func probe() -> Health {
        // 1. Check TCC accessibility grant
        guard AXIsProcessTrusted() else {
            return .dead
        }

        // 2. Check if the system auth prompt is blocking
        let authWarnRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.universalaccessAuthWarn"
        }
        if authWarnRunning {
            return .degraded("universalAccessAuthWarn dialog is open")
        }

        return .healthy
    }
}
