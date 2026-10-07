(mac-auto-bridge-backend-blueprint
  :schema "missiond.project-backend-blueprint.v1"
  :project-id mac-auto-bridge
  :source-sha "7ffce392b30b121215b5cdbd1cce5bfc091fd4e2"
  :kind local-swift-mcp-server
  :transport stdio-json-rpc
  :status current-code-aligned

  (domain-model
    :entities [mcp-request tool-call capture-frame ocr-entry accessibility-snapshot input-lease diagnostic]
    :boundary "Single-user local macOS process; no cloud API, database, account, billing, or durable OCR store.")

  (policy-layer
    :read-tools [snapshot look capture_window capture_to_file find_text_on_screen ax_snapshot list_windows list_displays get_selection diagnose]
    :write-tools [focus_app click click_text right_click context_menu_click drag type_text type_in_focused_field scroll press_key goto_folder subtitle_workflow export_srt]
    :write-gate "InputGate focus lease plus Accessibility permission and frontmost-app verification"
    :capture-gate "CaptureGate plus macOS Screen Recording permission"
    :auth-grade "Local process boundary: MCP host spawn authority + macOS TCC permissions; no network listener."
    :must-not-log [typed-text full-screen-image ocr-result-body secret-value])

  (flow-layer
    (function mcp-tool-call
      :entry [json-rpc-request tool-name arguments]
      :core ((step s1 :logic "MCPServer validates the request and resolves the registered BridgeTool.")
             (step s2 :logic "ToolRouter applies its wall-clock deadline and invokes the tool with gated context.")
             (step s3 :logic "The tool returns JSON-safe structured content; errors remain typed MCP results."))
      :egress [json-rpc-response diagnostic-event]
      :surfaces ["Sources/MacAutoBridge/Server/MCPServer.swift"
                 "Sources/MacAutoBridge/Server/ToolRouter.swift"
                 "Sources/MacAutoBridge/Tools/RegisterAll.swift"]
      :runtime-projection (transport stdio timeout-policy per-tool))

    (function capture-and-recognize
      :entry [bundle-id optional-window-title ocr-mode]
      :core ((step s1 :logic "CaptureSerializer serializes ScreenCaptureKit work and enforces a deadline.")
             (step s2 :logic "CaptureGate captures an app/window frame and selects Vision or local Paddle OCR.")
             (step s3 :logic "Coordinates are normalized to screen-global points; OCR entries stay in memory and are returned to the caller."))
      :egress [capture-frame ocr-entry-list]
      :surfaces ["Sources/MacAutoBridge/Perception/CaptureSerializer.swift"
                 "Sources/MacAutoBridge/Subsystem/CaptureGate.swift"
                 "Sources/MacAutoBridge/Perception/VisionOCR.swift"
                 "Sources/MacAutoBridge/OCR/PaddleOCREngine.swift"]
      :runtime-projection (persistence none coordinates screen-global)))

  (event-contract
    :events [(tool-call-started :fields [tool-name timestamp])
             (tool-call-finished :fields [tool-name duration-ms status])
             (capture-degraded :fields [reason fallback])
             (temporary-artifact-created :fields [kind path created-at retention-class])
             (temporary-artifact-pruned :fields [kind count cutoff])]
    :event-bus stderr-local-diagnostics
    :outbox none)

  (runtime-projection
    :binary ".build/release/MacAutoBridge"
    :protocol "MCP JSON-RPC 2.0 over stdio"
    :hot-path "MCPServer -> ToolRouter -> subsystem gate -> Apple framework / local ONNX Runtime"
    :durable-state none)

  (implementation-map
    :current-code ["Sources/MacAutoBridge/main.swift"
                   "Sources/MacAutoBridge/Server/MCPServer.swift"
                   "Sources/MacAutoBridge/Server/ToolRouter.swift"
                   "Sources/MacAutoBridge/Tools"
                   "Sources/MacAutoBridge/Subsystem"
                   "Sources/MacAutoBridge/Perception"
                   "Sources/MacAutoBridge/OCR"]
    :code-isomorphism "Project checker anchors runtime entry, MCP transport, capture serialization, and retention contract without mutating generated output.")

  (compatibility-ledger
    :active [mcp-protocol-2024-11-05 vision-ocr paddle-ocr-local]
    :legacy ["Sources/MacAutoBridge/Server/ToolRegistry.swift and MVPFacade compatibility paths remain present but main.swift registers ToolRouter/BridgeTool implementations."])

  (hot-path-wiring
    :entry "Sources/MacAutoBridge/main.swift"
    :router "Sources/MacAutoBridge/Server/ToolRouter.swift"
    :tool-registration "Sources/MacAutoBridge/Tools/RegisterAll.swift"
    :rule "Runtime OCR consumes in-process Apple/ONNX APIs; no raw MissionD Lisp is parsed on the hot path."))
