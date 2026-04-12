import ApplicationServices
import AppKit

final class AXManager: @unchecked Sendable {

    static let shared = AXManager()

    // MARK: - Permission

    func checkAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        )
    }

    // MARK: - Snapshot

    func snapshotApp(bundleID: String, maxDepth: Int = 5) throws -> AXNode {
        let pid = try findPID(bundleID: bundleID)
        let appElement = AXUIElementCreateApplication(pid)
        return buildTree(element: appElement, depth: 0, maxDepth: maxDepth)
    }

    func snapshotFocusedWindow(bundleID: String, maxDepth: Int = 5) throws -> AXNode {
        let pid = try findPID(bundleID: bundleID)
        let appElement = AXUIElementCreateApplication(pid)

        var windowValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard result == .success, let window = windowValue else {
            throw BridgeError.elementNotFound("No focused window for \(bundleID)")
        }

        // swiftlint:disable:next force_cast
        return buildTree(element: window as! AXUIElement, depth: 0, maxDepth: maxDepth)
    }

    // MARK: - Find

    func findElement(bundleID: String, query: AXQuery) throws -> AXNode? {
        let tree = try snapshotApp(bundleID: bundleID, maxDepth: 10)
        return searchTree(node: tree, query: query)
    }

    func findElements(bundleID: String, query: AXQuery) throws -> [AXNode] {
        let tree = try snapshotApp(bundleID: bundleID, maxDepth: 10)
        var results: [AXNode] = []
        collectMatches(node: tree, query: query, results: &results)
        return results
    }

    // MARK: - Selection (semantic alternative to visual selection inspection)

    /// Returns all elements currently marked as selected in the focused window.
    /// Walks the focused window subtree and collects elements where AXSelected==true,
    /// AXSelectedChildren is non-empty, or AXSelectedRows is non-empty.
    /// Use this instead of staring at a screenshot to decide whether items are selected.
    func getSelection(bundleID: String) throws -> [AXNode] {
        let pid = try findPID(bundleID: bundleID)
        let appElement = AXUIElementCreateApplication(pid)

        var windowValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard result == .success, let window = windowValue else {
            throw BridgeError.elementNotFound("No focused window for \(bundleID)")
        }

        var results: [AXNode] = []
        // swiftlint:disable:next force_cast
        collectSelected(element: window as! AXUIElement, depth: 0, maxDepth: 10, results: &results)
        return results
    }

    private func collectSelected(
        element: AXUIElement, depth: Int, maxDepth: Int, results: inout [AXNode]
    ) {
        if let selected = getAttribute(element, "AXSelected") as? Bool, selected {
            results.append(makeLeaf(element))
        }
        // Containers expose AXSelectedChildren / AXSelectedRows directly.
        for attr in ["AXSelectedChildren", "AXSelectedRows", "AXSelectedCells"] {
            if let children = getAttribute(element, attr) as? [AXUIElement] {
                for c in children {
                    results.append(makeLeaf(c))
                }
            }
        }
        guard depth < maxDepth,
            let children = getAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return }
        for c in children {
            collectSelected(element: c, depth: depth + 1, maxDepth: maxDepth, results: &results)
        }
    }

    private func makeLeaf(_ element: AXUIElement) -> AXNode {
        let role = getAttribute(element, kAXRoleAttribute) as? String ?? "Unknown"
        let subrole = getAttribute(element, kAXSubroleAttribute) as? String
        let title = getAttribute(element, kAXTitleAttribute) as? String
        let identifier = getAttribute(element, kAXIdentifierAttribute) as? String
        return AXNode(
            role: role, subrole: subrole, title: title,
            identifier: identifier, frame: getFrame(element), children: [])
    }

    // MARK: - Focused Element Value (for input verification)

    func getFocusedElementValue(bundleID: String) throws -> String? {
        let pid = try findPID(bundleID: bundleID)
        let appElement = AXUIElementCreateApplication(pid)

        var focusedRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard result == .success, let focused = focusedRef else { return nil }

        // swiftlint:disable:next force_cast
        return getAttribute(focused as! AXUIElement, kAXValueAttribute) as? String
    }

    // MARK: - AX Actions

    func performAction(bundleID: String, query: AXQuery, action: String = "AXPress") throws -> Bool {
        let pid = try findPID(bundleID: bundleID)
        let appElement = AXUIElementCreateApplication(pid)

        guard let element = findAXUIElement(root: appElement, query: query, depth: 0, maxDepth: 10)
        else {
            return false
        }

        return AXUIElementPerformAction(element, action as CFString) == .success
    }

    // MARK: - Private

    private func findPID(bundleID: String) throws -> pid_t {
        // Primary: NSWorkspace (more reliable for MCP child processes)
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) {
            return app.processIdentifier
        }
        // Fallback: direct API
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app.processIdentifier
        }
        throw BridgeError.appNotRunning(bundleID)
    }

    private func buildTree(element: AXUIElement, depth: Int, maxDepth: Int) -> AXNode {
        let role = getAttribute(element, kAXRoleAttribute) as? String ?? "Unknown"
        let subrole = getAttribute(element, kAXSubroleAttribute) as? String
        let title = getAttribute(element, kAXTitleAttribute) as? String
        let identifier = getAttribute(element, kAXIdentifierAttribute) as? String
        let frame = getFrame(element)

        var children: [AXNode] = []
        if depth < maxDepth,
            let childrenRef = getAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
        {
            children = childrenRef.map { child in
                buildTree(element: child, depth: depth + 1, maxDepth: maxDepth)
            }
        }

        return AXNode(
            role: role, subrole: subrole, title: title,
            identifier: identifier, frame: frame, children: children)
    }

    private func findAXUIElement(root: AXUIElement, query: AXQuery, depth: Int, maxDepth: Int)
        -> AXUIElement?
    {
        let role = getAttribute(root, kAXRoleAttribute) as? String ?? ""
        let title = getAttribute(root, kAXTitleAttribute) as? String
        let identifier = getAttribute(root, kAXIdentifierAttribute) as? String
        let temp = AXNode(
            role: role, subrole: nil, title: title,
            identifier: identifier, frame: .zero, children: [])
        if query.matches(temp) { return root }

        guard depth < maxDepth,
            let children = getAttribute(root, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }

        for child in children {
            if let found = findAXUIElement(root: child, query: query, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private func getAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value
    }

    private func getFrame(_ element: AXUIElement) -> CGRect {
        var position = CGPoint.zero
        var size = CGSize.zero

        if let posValue = getAttribute(element, kAXPositionAttribute) {
            // swiftlint:disable:next force_cast
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        }
        if let sizeValue = getAttribute(element, kAXSizeAttribute) {
            // swiftlint:disable:next force_cast
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }

    private func searchTree(node: AXNode, query: AXQuery) -> AXNode? {
        if query.matches(node) { return node }
        for child in node.children {
            if let found = searchTree(node: child, query: query) { return found }
        }
        return nil
    }

    private func collectMatches(node: AXNode, query: AXQuery, results: inout [AXNode]) {
        if query.matches(node) { results.append(node) }
        for child in node.children {
            collectMatches(node: child, query: query, results: &results)
        }
    }
}
