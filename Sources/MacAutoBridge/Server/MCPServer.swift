import Foundation

final class MCPServer: @unchecked Sendable {

    private let registry = ToolRegistry()

    init() {
        log("MCPServer initialized")
    }

    func handleLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            if let response = try await processMessage(trimmed) {
                let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                if let jsonString = String(data: data, encoding: .utf8) {
                    log("stdout >> \(jsonString.prefix(200))")
                    print(jsonString)
                    fflush(stdout)
                }
            }
        } catch {
            log("ERROR: \(error)")
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
                "serverInfo": ["name": "MacAutoBridge", "version": "0.1.0"],
            ])

        case "ping":
            return ok(id: id, result: [:])

        case "tools/list":
            return ok(id: id, result: ["tools": registry.listTools()])

        case "tools/call":
            let params = json["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]

            // Wall-clock guard: Codex MCP client kills any call at 120s.
            // Cap every tool at 100s so we always return a clean response
            // instead of getting silently killed mid-flight.
            do {
                let result = try await withToolTimeout(seconds: 100) {
                    try await self.registry.callTool(name: toolName, arguments: arguments)
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

    // MARK: - Timeout

    private func withToolTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BridgeError.verificationFailed(
                    step: "tool_timeout",
                    detail: "Tool call exceeded \(Int(seconds))s wall-clock limit")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
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
