import Foundation

final class ToolRouter: @unchecked Sendable {
    private var schemas: [String: any BridgeTool.Type] = [:]
    private var factories: [String: @Sendable () -> any BridgeTool] = [:]

    func register<T: BridgeTool>(_ tool: T.Type) where T: Initializable {
        schemas[tool.name] = tool
        factories[tool.name] = { T() }
    }

    func listTools() -> [[String: Any]] {
        schemas.values.map { $0.schema.toMCP(name: $0.name) }
    }

    func callTool(name: String, arguments: [String: Any], ctx: ToolContext) async throws -> [String: Any] {
        guard let factory = factories[name] else {
            return textResult("Unknown tool: \(name)", isError: true)
        }
        return try await factory().execute(args: arguments, ctx: ctx)
    }

    func timeout(for toolName: String) -> TimeInterval {
        schemas[toolName]?.timeout ?? 100
    }
}

/// Marker protocol for types that can be constructed with no arguments.
/// All BridgeTool structs (stateless, no stored properties) conform automatically.
protocol Initializable { init() }

// MARK: - Conformances

extension FocusAppTool: Initializable {}
extension ListWindowsTool: Initializable {}
extension ListDisplaysTool: Initializable {}
extension AXSnapshotTool: Initializable {}
extension GetSelectionTool: Initializable {}
extension CaptureWindowTool: Initializable {}
extension FindTextTool: Initializable {}
extension ClickTool: Initializable {}
extension TypeTextTool: Initializable {}
extension ScrollTool: Initializable {}
extension PressKeyTool: Initializable {}
extension DragTool: Initializable {}

// MARK: - Batch Registration (Perception + Action — 12 tools)

func registerPerceptionAndActionTools(_ router: ToolRouter) {
    // Perception (7)
    router.register(FocusAppTool.self)
    router.register(ListWindowsTool.self)
    router.register(ListDisplaysTool.self)
    router.register(AXSnapshotTool.self)
    router.register(GetSelectionTool.self)
    router.register(CaptureWindowTool.self)
    router.register(FindTextTool.self)

    // Action (5)
    router.register(ClickTool.self)
    router.register(TypeTextTool.self)
    router.register(ScrollTool.self)
    router.register(PressKeyTool.self)
    router.register(DragTool.self)
}
