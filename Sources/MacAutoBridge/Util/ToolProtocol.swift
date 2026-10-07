import Foundation

// MARK: - BridgeTool Protocol

/// Every MCP tool conforms to this protocol. One file per tool.
/// The ToolRouter auto-collects conformers at startup.
protocol BridgeTool {
    /// Tool name as exposed via MCP (e.g. "click", "snapshot", "look")
    static var name: String { get }

    /// JSON Schema for the tool's inputSchema, in MCP format.
    static var schema: ToolSchema { get }

    /// Wall-clock timeout for this tool. Default 100s.
    /// Long-running workflow tools can override to e.g. 600s.
    static var timeout: TimeInterval { get }

    /// Execute the tool. Throws BridgeError on failure.
    func execute(args: [String: Any], ctx: ToolContext) async throws -> [String: Any]
}

extension BridgeTool {
    static var timeout: TimeInterval { 100 }
}

// MARK: - Tool Schema

struct ToolSchema {
    let description: String
    let properties: [String: [String: Any]]
    let required: [String]

    func toMCP(name: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ] as [String: Any],
        ]
    }
}

// MARK: - Schema Helpers

func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }

// MARK: - Tool Context

/// Injected into every tool — provides access to the three subsystem gates.
struct ToolContext: @unchecked Sendable {
    let ax: AXGate
    let capture: CaptureGate
    let input: InputGate
    let health: HealthMonitor
}

// MARK: - Result Helpers

func textResult(_ text: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": isError]
}

func jsonResult(_ value: Any) -> [String: Any] {
    let data =
        (try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? "null"
    return ["content": [["type": "text", "text": text]]]
}

// rectCenter is defined in SharedTypes.swift — do not duplicate here

// MARK: - OCR Text Normalization

/// Shorten long text for OCR matching. OCR often breaks long filenames across lines.
/// "podcast-ep104-sample.mp3" → "ep104" (extract episode-like pattern)
/// "some,keywords" → passed through (already multi-keyword)
/// Short text (≤15 chars) → passed through unchanged
func shortenForOCR(_ text: String) -> String {
    if text.contains(",") { return text }
    if text.count <= 15 { return text }

    let nsText = text as NSString
    let regex = try? NSRegularExpression(pattern: "[eE][pP]\\d+", options: [])
    if let match = regex?.firstMatch(
        in: text, range: NSRange(location: 0, length: nsText.length))
    {
        return nsText.substring(with: match.range)
    }

    let segments = text.components(separatedBy: CharacterSet(charactersIn: "-._/ "))
        .filter { $0.count >= 3 }
    if let best = segments.max(by: { $0.count < $1.count }), best.count <= 20 {
        return best
    }

    return String(text.prefix(12))
}
