@preconcurrency import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class ToolRegistry: @unchecked Sendable {

    private let focus = FocusManager.shared
    private let ax = AXManager.shared
    private let ocr = OCRManager.shared
    private let events = EventSynthesizer.shared
    private let locator = LocatorEngine.shared
    private let display = DisplayManager.shared
    private let transaction = TransactionRunner.shared
    private let mvp = MVPFacade.shared

    // MARK: - Tool Definitions

    func listTools() -> [[String: Any]] {
        [
            // ── Perception ──
            tool(
                "focus_app",
                desc: "Focus an application by bundle ID and optionally verify window title",
                props: [
                    "bundle_id": str("App bundle identifier, e.g. com.lemon.lvpro"),
                    "expected_window_title": str("Optional: expected window title substring"),
                ],
                required: ["bundle_id"]),

            tool(
                "list_windows",
                desc: "List visible windows, optionally filtered by bundle ID",
                props: ["bundle_id": str("Optional: filter by bundle identifier")],
                required: []),

            tool(
                "list_displays",
                desc: "List active displays with bounds and scale factors",
                props: [:], required: []),

            tool(
                "ax_snapshot",
                desc: "Get the accessibility tree for an app's focused window",
                props: [
                    "bundle_id": str("App bundle identifier"),
                    "max_depth": int("Max tree depth (default 5)"),
                ],
                required: ["bundle_id"]),

            tool(
                "capture_window",
                desc:
                    "Capture a window screenshot and run OCR, returns text entries with screen-global coordinates",
                props: [
                    "bundle_id": str("App bundle identifier"),
                    "window_title": str("Optional: window title substring"),
                ],
                required: ["bundle_id"]),

            tool(
                "find_text_on_screen",
                desc: "Find text on screen via OCR, returns matching entries with coordinates",
                props: [
                    "text": str("Text to search for"),
                    "bundle_id": str("Optional: limit search to this app's windows"),
                ],
                required: ["text"]),

            // ── Action ──
            tool(
                "click",
                desc:
                    "Click at a target (OCR text / AX element / coordinates). Verifies focus before acting.",
                props: [
                    "bundle_id": str("App bundle identifier for focus lock"),
                    "target_text": str("Click on this text (found via OCR)"),
                    "target_x": num("Click at X coordinate"),
                    "target_y": num("Click at Y coordinate"),
                    "target_ax_role": str("AX element role"),
                    "target_ax_title": str("AX element title"),
                    "target_ax_id": str("AX element identifier"),
                    "nth": int("Which occurrence to click (default 1)"),
                    "clicks": int("Number of clicks (default 1)"),
                ],
                required: ["bundle_id"]),

            tool(
                "type_text",
                desc:
                    "Type text into the focused application. Verifies focus before and during typing.",
                props: [
                    "bundle_id": str("App bundle identifier for focus lock"),
                    "text": str("Text to type"),
                    "verify_text": str("Optional: verify this text appears after typing"),
                ],
                required: ["bundle_id", "text"]),

            tool(
                "scroll",
                desc: "Scroll at a position. Positive delta_y = down, negative = up.",
                props: [
                    "bundle_id": str("App bundle identifier"),
                    "x": num("Scroll position X"),
                    "y": num("Scroll position Y"),
                    "delta_y": num("Scroll amount (positive=down, negative=up)"),
                ],
                required: ["bundle_id", "delta_y"]),

            tool(
                "press_key",
                desc: "Press a keyboard key with optional modifiers",
                props: [
                    "bundle_id": str("App bundle identifier for focus lock"),
                    "key_code": int("CGKeyCode value"),
                    "command": bool("Hold Command"), "shift": bool("Hold Shift"),
                    "option": bool("Hold Option"), "control": bool("Hold Control"),
                ],
                required: ["bundle_id", "key_code"]),

            tool(
                "drag",
                desc:
                    "Drag from one point to another (10-step interpolated). Use for timeline manipulation, moving items, etc.",
                props: [
                    "bundle_id": str("App bundle identifier for focus lock"),
                    "from_x": num("Start X coordinate"),
                    "from_y": num("Start Y coordinate"),
                    "to_x": num("End X coordinate"),
                    "to_y": num("End Y coordinate"),
                ],
                required: ["bundle_id", "from_x", "from_y", "to_x", "to_y"]),

            tool(
                "right_click",
                desc:
                    "Right-click at a target to open context menu. Supports OCR text or coordinates.",
                props: [
                    "bundle_id": str("App bundle identifier for focus lock"),
                    "target_text": str("Right-click on this text (found via OCR)"),
                    "x": num("Right-click at X coordinate"),
                    "y": num("Right-click at Y coordinate"),
                    "nth": int("Which occurrence of target_text (default 1)"),
                ],
                required: ["bundle_id"]),

            // ── Transaction ──
            tool(
                "wait_until",
                desc: "Wait until a condition is met (text appears/disappears, AX element, window)",
                props: [
                    "bundle_id": str("App bundle identifier"),
                    "text_appears": str("Wait for this text to appear on screen"),
                    "text_disappears": str("Wait for this text to disappear"),
                    "ax_role": str("Wait for AX element with this role"),
                    "ax_title": str("Wait for AX element with this title"),
                    "window_title": str("Wait for window with this title"),
                    "timeout": num("Timeout in seconds (default 10)"),
                ],
                required: ["bundle_id"]),

            // ── MVP Facade ──
            tool(
                "focus_and_assert",
                desc: "[MVP] Focus app and assert expected window title",
                props: [
                    "bundle_id": str("App bundle identifier"),
                    "expected_window_title": str("Expected window title"),
                ],
                required: ["bundle_id"]),

            tool(
                "capture_app",
                desc: "[MVP] Capture app window + OCR, returns text entries with coordinates",
                props: ["bundle_id": str("App bundle identifier")],
                required: ["bundle_id"]),

            tool(
                "click_text",
                desc: "[MVP] Click on text found via OCR in the target app",
                props: [
                    "bundle_id": str("App bundle identifier"),
                    "text": str("Text to click on"),
                    "nth": int("Which occurrence (default 1)"),
                ],
                required: ["bundle_id", "text"]),

            tool(
                "type_in_focused_field",
                desc: "[MVP] Type text into the focused field with optional verification",
                props: [
                    "bundle_id": str("App bundle identifier"),
                    "text": str("Text to type"),
                    "verify_text": str("Optional: verify this text appears after typing"),
                ],
                required: ["bundle_id", "text"]),

            // ── High-Level Workflows ──
            tool(
                "snapshot",
                desc:
                    "All-in-one observation: returns window list + focused window AX tree (depth 3). Set include_ocr=true to also capture+OCR (slower). Default is fast mode without OCR.",
                props: [
                    "bundle_id": str("App bundle identifier"),
                    "include_ocr": bool("Include OCR text entries (slower, default false)"),
                ],
                required: ["bundle_id"]),

            tool(
                "goto_folder",
                desc:
                    "Navigate to a folder in a macOS file dialog (Open/Save panel). Sends Cmd+Shift+G, types the path, and presses Enter. Verifies the folder name appears after navigation.",
                props: [
                    "bundle_id": str("App bundle identifier"),
                    "path": str("Absolute path to navigate to, e.g. /Users/me/Downloads"),
                ],
                required: ["bundle_id", "path"]),

            // ── Diagnostics ──
            tool(
                "diagnose",
                desc:
                    "Diagnose runtime environment: permissions, app visibility, window server access",
                props: [:], required: []),
        ]
    }

    // MARK: - Tool Dispatch

    func callTool(name: String, arguments args: [String: Any]) async throws -> [String: Any] {
        switch name {

        // ── Perception ──

        case "focus_app":
            let bid = args["bundle_id"] as! String
            let title = args["expected_window_title"] as? String
            let ok = try await mvp.focusAndAssert(bundleID: bid, windowTitle: title)
            return textResult(
                "Focused \(bid)" + (title.map { ", verified window: \($0)" } ?? ""), isError: !ok)

        case "list_windows":
            let windows = focus.listWindows(bundleID: args["bundle_id"] as? String)
            return jsonResult(windows.map { $0.toJSON() })

        case "list_displays":
            return jsonResult(display.listDisplays().map { $0.toJSON() })

        case "ax_snapshot":
            let bid = args["bundle_id"] as! String
            let depth = args["max_depth"] as? Int ?? 5
            let tree = try ax.snapshotFocusedWindow(bundleID: bid, maxDepth: depth)
            return jsonResult(tree.toJSON())

        case "capture_window":
            let bid = args["bundle_id"] as! String
            let title = args["window_title"] as? String
            let (image, entries) = try await ocr.captureAndRecognize(
                bundleID: bid, windowTitle: title)
            return jsonResult([
                "width": image.width, "height": image.height,
                "text_entries": entries.map { $0.toJSON() },
            ] as [String: Any])

        case "find_text_on_screen":
            let text = args["text"] as! String
            let entries = try await ocr.findTextOnScreen(
                text: text, bundleID: args["bundle_id"] as? String)
            return jsonResult(entries.map { $0.toJSON() })

        // ── Action ──

        case "click":
            let bid = args["bundle_id"] as! String
            let clicks = args["clicks"] as? Int ?? 1
            let nth = args["nth"] as? Int ?? 1
            let target = resolveTarget(from: args)
            _ = try await focus.acquire(bundleID: bid)
            defer { focus.release() }
            let rect = try await locator.resolve(locator: target, bundleID: bid, nth: nth)
            let center = rectCenter(rect)
            try events.click(at: center, clicks: clicks)
            return textResult("Clicked at (\(Int(center.x)), \(Int(center.y)))")

        case "type_text":
            let bid = args["bundle_id"] as! String
            let text = args["text"] as! String
            let verify = args["verify_text"] as? String
            let ok = try await mvp.typeInFocusedField(
                bundleID: bid, text: text, verifyText: verify)
            return textResult("Typed \(text.count) chars", isError: !ok)

        case "scroll":
            let bid = args["bundle_id"] as! String
            let x = args["x"] as? Double ?? 0
            let y = args["y"] as? Double ?? 0
            let deltaY = args["delta_y"] as! Double
            _ = try await focus.acquire(bundleID: bid)
            defer { focus.release() }
            try events.scroll(at: CGPoint(x: x, y: y), deltaY: Int32(deltaY))
            return textResult("Scrolled \(deltaY)")

        case "press_key":
            let bid = args["bundle_id"] as! String
            let keyCode = UInt16(args["key_code"] as! Int)
            var flags: CGEventFlags = []
            if args["command"] as? Bool == true { flags.insert(.maskCommand) }
            if args["shift"] as? Bool == true { flags.insert(.maskShift) }
            if args["option"] as? Bool == true { flags.insert(.maskAlternate) }
            if args["control"] as? Bool == true { flags.insert(.maskControl) }
            _ = try await focus.acquire(bundleID: bid)
            defer { focus.release() }
            try events.pressKey(keyCode: keyCode, flags: flags)
            return textResult("Pressed key \(keyCode)")

        case "drag":
            let bid = args["bundle_id"] as! String
            let fromX = args["from_x"] as! Double
            let fromY = args["from_y"] as! Double
            let toX = args["to_x"] as! Double
            let toY = args["to_y"] as! Double
            _ = try await focus.acquire(bundleID: bid)
            defer { focus.release() }
            try events.drag(
                from: CGPoint(x: fromX, y: fromY),
                to: CGPoint(x: toX, y: toY))
            return textResult(
                "Dragged (\(Int(fromX)),\(Int(fromY))) → (\(Int(toX)),\(Int(toY)))")

        case "right_click":
            let bid = args["bundle_id"] as! String
            let nth = args["nth"] as? Int ?? 1
            _ = try await focus.acquire(bundleID: bid)
            defer { focus.release() }
            let point: CGPoint
            if let text = args["target_text"] as? String {
                let rect = try await locator.resolve(
                    locator: .ocr(text), bundleID: bid, nth: nth)
                point = rectCenter(rect)
            } else {
                let x = args["x"] as? Double ?? 0
                let y = args["y"] as? Double ?? 0
                point = CGPoint(x: x, y: y)
            }
            try events.click(at: point, button: .right)
            return textResult("Right-clicked at (\(Int(point.x)), \(Int(point.y)))")

        // ── Transaction ──

        case "wait_until":
            let bid = args["bundle_id"] as! String
            let timeout = args["timeout"] as? Double ?? 10.0
            let condition: VerificationCondition
            if let t = args["text_appears"] as? String { condition = .textAppears(t) }
            else if let t = args["text_disappears"] as? String { condition = .textDisappears(t) }
            else if let t = args["window_title"] as? String { condition = .windowAppears(t) }
            else if let t = args["ax_title"] as? String {
                condition = .axExists(AXQuery(role: args["ax_role"] as? String, title: t))
            } else {
                return textResult("No condition specified", isError: true)
            }
            try await transaction.waitForCondition(condition, bundleID: bid, timeout: timeout)
            return textResult("Condition met")

        // ── MVP Facade ──

        case "focus_and_assert":
            let bid = args["bundle_id"] as! String
            let ok = try await mvp.focusAndAssert(
                bundleID: bid, windowTitle: args["expected_window_title"] as? String)
            return textResult("Focus verified", isError: !ok)

        case "capture_app":
            let bid = args["bundle_id"] as! String
            let (image, entries) = try await mvp.captureApp(bundleID: bid)
            return jsonResult([
                "width": image.width, "height": image.height,
                "entry_count": entries.count,
                "text_entries": entries.map { $0.toJSON() },
            ] as [String: Any])

        case "click_text":
            let bid = args["bundle_id"] as! String
            let text = args["text"] as! String
            let nth = args["nth"] as? Int ?? 1
            let ok = try await mvp.clickText(bundleID: bid, text: text, nth: nth)
            return textResult("Clicked text '\(text)'", isError: !ok)

        case "type_in_focused_field":
            let bid = args["bundle_id"] as! String
            let text = args["text"] as! String
            let verify = args["verify_text"] as? String
            let ok = try await mvp.typeInFocusedField(
                bundleID: bid, text: text, verifyText: verify)
            return textResult("Typed \(text.count) chars", isError: !ok)

        case "snapshot":
            let bid = args["bundle_id"] as! String
            let includeOCR = args["include_ocr"] as? Bool ?? false
            let result = try await mvp.snapshot(bundleID: bid, includeOCR: includeOCR)
            return jsonResult(result)

        case "goto_folder":
            let bid = args["bundle_id"] as! String
            let path = args["path"] as! String
            let ok = try await mvp.gotoFolder(bundleID: bid, path: path)
            return textResult("Navigated to \(path)", isError: !ok)

        case "diagnose":
            return jsonResult(runDiagnostics())

        default:
            return textResult("Unknown tool: \(name)", isError: true)
        }
    }

    // MARK: - Diagnostics

    private func runDiagnostics() -> [String: Any] {
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

        return d
    }

    // MARK: - Private Helpers

    private func resolveTarget(from args: [String: Any]) -> TargetLocator {
        if let text = args["target_text"] as? String { return .ocr(text) }
        if let x = args["target_x"] as? Double, let y = args["target_y"] as? Double {
            return .coordinate(CGPoint(x: x, y: y))
        }
        if args["target_ax_role"] != nil || args["target_ax_title"] != nil
            || args["target_ax_id"] != nil
        {
            return .ax(
                AXQuery(
                    role: args["target_ax_role"] as? String,
                    title: args["target_ax_title"] as? String,
                    identifier: args["target_ax_id"] as? String))
        }
        return .coordinate(.zero)
    }

    private func textResult(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func jsonResult(_ value: Any) -> [String: Any] {
        let data =
            (try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "null"
        return ["content": [["type": "text", "text": text]]]
    }

    // ── Schema helpers ──

    private func tool(_ name: String, desc: String, props: [String: [String: Any]], required: [String])
        -> [String: Any]
    {
        [
            "name": name, "description": desc,
            "inputSchema": ["type": "object", "properties": props, "required": required],
        ]
    }
    private func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
}
