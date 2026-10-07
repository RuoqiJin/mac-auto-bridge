import Foundation

final class MCPServer: @unchecked Sendable {

    private let router: ToolRouter
    private let ctx: ToolContext

    init(router: ToolRouter, ctx: ToolContext) {
        self.router = router
        self.ctx = ctx
        log("MCPServer initialized")
    }

    func handleLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            if let response = try await processMessage(trimmed) {
                let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                if let jsonString = String(data: data, encoding: .utf8) {
                    log("stdout response sent (\(data.count) bytes)")
                    print(jsonString)
                    fflush(stdout)
                }
            }
        } catch {
            log("ERROR: request processing failed")
            if let data = trimmed.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = json["id"]
            {
                sendError(id: id, code: -32603, message: "\(error)")
            }
        }
    }

    // MARK: - Message Dispatch

    private func processMessage(_ line: String) async throws -> [String: Any]? {
        guard let data = line.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let method = json["method"] as? String

        // Notifications have no id → no response
        guard let id = json["id"] else { return nil }

        switch method {
        case "initialize":
            return ok(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "MacAutoBridge", "version": "0.2.0"],
            ])

        case "ping":
            return ok(id: id, result: [:])

        case "tools/list":
            return ok(id: id, result: ["tools": router.listTools()])

        case "tools/call":
            let params = json["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]

            // Wall-clock guard: per-tool timeout (default 100s).
            // Long-running workflow tools can override to e.g. 600s.
            let toolTimeout = router.timeout(for: toolName)
            do {
                let result = try await withDeadline(seconds: toolTimeout, step: "tool_timeout") {
                    try await self.router.callTool(
                        name: toolName, arguments: arguments, ctx: self.ctx)
                }
                return ok(id: id, result: result)
            } catch {
                let msg = "\(error.localizedDescription)"
                let isTimeout = msg.contains("tool_timeout")
                return ok(id: id, result: [
                    "content": [["type": "text", "text": isTimeout
                        ? "Tool '\(toolName)' exceeded 100s wall-clock limit. The Bridge process may be under load. Try again or use a simpler alternative."
                        : "Error: \(msg)"]],
                    "isError": true,
                ])
            }

        default:
            return err(id: id, code: -32601, message: "Method not found: \(method ?? "nil")")
        }
    }

    // MARK: - JSON-RPC Helpers

    private func ok(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func err(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func sendError(id: Any, code: Int, message: String) {
        let resp = err(id: id, code: code, message: message)
        if let data = try? JSONSerialization.data(withJSONObject: resp),
            let str = String(data: data, encoding: .utf8)
        {
            print(str)
            fflush(stdout)
        }
    }
}
