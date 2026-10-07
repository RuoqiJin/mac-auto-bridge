import Foundation

// MARK: - Initializable Conformances (Composite + Diagnostic)

extension FocusAndAssertTool: Initializable {}
extension CaptureAppTool: Initializable {}
extension ClickTextTool: Initializable {}
extension TypeInFieldTool: Initializable {}
extension SnapshotTool: Initializable {}
extension LookTool: Initializable {}
extension CaptureToFileTool: Initializable {}
extension ContextMenuClickTool: Initializable {}
extension RightClickTool: Initializable {}
extension WatchProgressTool: Initializable {}
extension ScrollUntilTextTool: Initializable {}
extension GotoFolderTool: Initializable {}
extension WaitUntilTool: Initializable {}
extension SubtitleWorkflowTool: Initializable {}
extension ExportSrtTool: Initializable {}
extension DiagnoseTool: Initializable {}

// MARK: - Register All 27 Tools

func registerAllTools(_ router: ToolRouter) {
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

    // Composite (12)
    router.register(FocusAndAssertTool.self)
    router.register(CaptureAppTool.self)
    router.register(ClickTextTool.self)
    router.register(TypeInFieldTool.self)
    router.register(SnapshotTool.self)
    router.register(LookTool.self)
    router.register(CaptureToFileTool.self)
    router.register(ContextMenuClickTool.self)
    router.register(RightClickTool.self)
    router.register(WatchProgressTool.self)
    router.register(ScrollUntilTextTool.self)
    router.register(GotoFolderTool.self)
    router.register(WaitUntilTool.self)
    router.register(SubtitleWorkflowTool.self)
    router.register(ExportSrtTool.self)

    // Diagnostic (1)
    router.register(DiagnoseTool.self)
}
