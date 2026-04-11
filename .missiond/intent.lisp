;; ============================================================
;; MacAutoBridge — Intent Declaration
;; Generated: 2026-04-11 | Forge Deep Cartography v3
;; ============================================================
;; State-aware macOS GUI Automation MCP Server
;; Pure Swift, zero external dependencies
;; 5-pillar architecture: Perception / Action / Transaction / Facade / Server
;; macOS 14+ | Swift 5.10+ | MCP JSON-RPC 2.0 over stdio

(intent mac-auto-bridge
  (granularity L3-implementation)

  (design-constraints
    (constraint zero-deps
      :rule "No external SPM dependencies — pure Apple frameworks only"
      :evidence "Package.swift has no .package() entries")
    (constraint focus-safety
      :rule "Every write action must verify focus before execution, abort on focusLost"
      :evidence "EventSynthesizer.click/drag/scroll/typeText all call focus.verify()")
    (constraint screen-global-coords
      :rule "All coordinates in screen-global space, auto-scaled for Retina + multi-display"
      :evidence "OCRManager transforms window-local → global; DisplayManager tracks scale factors")
    (constraint singleton-managers
      :rule "Thread-safe shared instances for all managers (@unchecked Sendable)"
      :evidence "FocusManager.shared, AXManager.shared, OCRManager.shared, LocatorEngine.shared")
    (constraint async-first
      :rule "All I/O is async/await, no blocking on main thread"
      :evidence "main.swift: stdin on detached thread, RunLoop.main.run() for AppKit"))

  ;; ── Pillar 1: Perception (Read-Only Sensors) ──────────────

  (pillar perception
    :purpose "Read-only observation of macOS UI state via AX + OCR + display topology"

    (component ax-observer
      :target "Sources/MacAutoBridge/Perception/AXObserver.swift"
      :doc "Accessibility API tree builder — snapshotApp/snapshotFocusedWindow/findElement/performAction"
      :struct "AXManager"
      :capabilities (snapshot-app snapshot-focused-window find-element find-elements perform-action)
      :limits (max-depth 10 default-depth 5))

    (component vision-ocr
      :target "Sources/MacAutoBridge/Perception/VisionOCR.swift"
      :doc "Vision Framework OCR + ScreenCaptureKit window capture"
      :struct "OCRManager"
      :capabilities (capture-and-recognize find-text-on-screen recognize-text)
      :languages ("zh-Hans" "zh-Hant" "en-US")
      :coordinate-transform "window-local → screen-global with Retina scaling")

    (component hybrid-locator
      :target "Sources/MacAutoBridge/Perception/HybridLocator.swift"
      :doc "AX→OCR→coordinate fallback resolution chain"
      :struct "LocatorEngine"
      :fallback-chain (ax ocr coordinate)
      :supports-nth true)

    (component screen-topology
      :target "Sources/MacAutoBridge/Perception/ScreenTopology.swift"
      :doc "Display enumeration — bounds, scale factors, multi-monitor layout"
      :struct "DisplayManager"))

  ;; ── Pillar 2: Action (Write-Only Actuators) ───────────────

  (pillar action
    :purpose "CGEvent synthesis for mouse/keyboard + app focus management"

    (component focus-manager
      :target "Sources/MacAutoBridge/Action/FocusManager.swift"
      :doc "App focus acquisition/verification/release — 2s timeout, 100ms poll"
      :struct "FocusManager"
      :capabilities (focus-app acquire verify release list-windows current-bundle-id))

    (component event-synthesizer
      :target "Sources/MacAutoBridge/Action/EventSynthesizer.swift"
      :doc "CGEvent mouse click/drag/scroll + keyboard typeText/pressKey"
      :struct "EventSynthesizer"
      :capabilities (click drag scroll type-text press-key)
      :safety "All methods call focus.verify() before execution"
      :details (
        (click :delay "20μs down/up" :multi-click true)
        (drag :interpolation "10 steps")
        (type-text :chunk-size 8 :re-verify-every 64)
        (press-key :modifiers (command shift option control)))))

  ;; ── Pillar 3: Transaction (Observe→Judge→Act→Verify) ──────

  (pillar transaction
    :purpose "Multi-step action sequences with verification conditions"

    (component transaction-runner
      :target "Sources/MacAutoBridge/Transaction/TransactionRunner.swift"
      :doc "Execute TransactionStep[] with locate→act→verify per step, 100ms inter-step pause"
      :struct "TransactionRunner"
      :capabilities (run wait-for-condition)
      :verification-conditions (text-appears text-disappears ax-exists window-appears)
      :poll-interval "500ms"
      :default-timeout "10s"))

  ;; ── Pillar 4: State Facade (MVP Convenience) ──────────────

  (pillar facade
    :purpose "4 high-level methods — simplified API for common automation patterns"

    (component mvp-facade
      :target "Sources/MacAutoBridge/Transaction/MVPFacade.swift"
      :doc "focus-and-assert / capture-app / click-text / type-in-focused-field"
      :struct "MVPFacade"
      :methods (
        (focus-and-assert :doc "Activate app + optional window title verify")
        (capture-app :doc "Screenshot + OCR → {width, height, entries[]}")
        (click-text :doc "OCR-find text → click center → verify focus")
        (type-in-focused-field :doc "Type into focused field → optional OCR verify"))))

  ;; ── Pillar 5: Server (MCP JSON-RPC 2.0) ───────────────────

  (pillar server
    :purpose "JSON-RPC 2.0 over stdio — MCP protocol implementation"

    (component mcp-server
      :target "Sources/MacAutoBridge/Server/MCPServer.swift"
      :doc "JSON-RPC request dispatcher — initialize/ping/tools-list/tools-call"
      :struct "MCPServer"
      :protocol-version "2024-11-05")

    (component tool-registry
      :target "Sources/MacAutoBridge/Server/ToolRegistry.swift"
      :doc "15 tool definitions + dispatch logic"
      :struct "ToolRegistry"
      :tool-count 15))

  ;; ── Entry Point ────────────────────────────────────────────

  (component entry
    :target "Sources/MacAutoBridge/main.swift"
    :doc "Detached stdin reader → async JSON-RPC loop + RunLoop.main.run()"
    :threading "stdin on detached thread, AppKit/AX/CGEvent on main")

  ;; ── Shared Types ───────────────────────────────────────────

  (component shared-types
    :target "Sources/MacAutoBridge/Types/SharedTypes.swift"
    :doc "All data types + BridgeError enum"
    :types (
      ;; Perception
      (struct AXNode :fields (role subrole title identifier frame children))
      (struct AXQuery :fields (role title identifier) :method "matches(_ node) -> Bool")
      (struct OCRTextEntry :fields (text frame confidence))
      (struct DisplayInfo :fields (displayID bounds scale))
      (struct WindowInfo :fields (windowID title bundleID frame isOnScreen))
      ;; Action
      (enum TargetLocator :variants (ax ocr coordinate))
      (enum ActionKind :variants (click typeText scroll))
      ;; Transaction
      (struct TransactionStep :fields (name locator action verify timeout))
      (enum VerificationCondition :variants (textAppears textDisappears axExists windowAppears))
      ;; Error
      (enum BridgeError :variants (focusLost elementNotFound verificationFailed
                                   transactionAborted accessibilityDenied
                                   screenCaptureDenied timeout appNotRunning))))

  ;; ── MCP Tools (15 total) ───────────────────────────────────

  (tools
    :doc "15 MCP tools exposed via JSON-RPC 2.0"

    ;; Perception (6)
    (tool focus_app :category perception :focus-lock acquire
      :params ((bundle_id String :required) (window_title String)))
    (tool list_windows :category perception :focus-lock none
      :params ((bundle_id String)))
    (tool list_displays :category perception :focus-lock none)
    (tool ax_snapshot :category perception :focus-lock none
      :params ((bundle_id String :required) (depth Integer)))
    (tool capture_window :category perception :focus-lock none
      :params ((bundle_id String :required) (title String)))
    (tool find_text_on_screen :category perception :focus-lock none
      :params ((text String :required) (bundle_id String)))

    ;; Action (4)
    (tool click :category action :focus-lock acquire-release
      :params ((bundle_id String :required)
               (target_ax_role String) (target_ax_title String) (target_ax_id String)
               (target_ocr String) (target_x Float) (target_y Float)
               (count Integer) (nth Integer)))
    (tool type_text :category action :focus-lock acquire-release
      :params ((bundle_id String :required) (text String :required) (verify Boolean)))
    (tool scroll :category action :focus-lock acquire-release
      :params ((bundle_id String :required) (x Float) (y Float) (delta_y Float :required)))
    (tool press_key :category action :focus-lock acquire-release
      :params ((bundle_id String :required) (key_code Integer :required) (flags Integer)))

    ;; Transaction (1)
    (tool wait_until :category transaction :focus-lock none
      :params ((bundle_id String :required)
               (text_appears String) (text_disappears String)
               (ax_exists_role String) (ax_exists_title String)
               (window_appears String) (timeout Float)))

    ;; MVP Facade (4)
    (tool focus_and_assert :category mvp :focus-lock none
      :params ((bundle_id String :required) (window_title String)))
    (tool capture_app :category mvp :focus-lock none
      :params ((bundle_id String :required)))
    (tool click_text :category mvp :focus-lock acquire-release
      :params ((bundle_id String :required) (text String :required) (nth Integer)))
    (tool type_in_focused_field :category mvp :focus-lock acquire-release
      :params ((bundle_id String :required) (text String :required) (verify Boolean))))

  ;; ── System Requirements ────────────────────────────────────

  (requirements
    (platform macos :min-version 14)
    (swift :min-version "5.10")
    (permissions
      (accessibility :purpose "AX API + CGEvent synthesis" :prompt "System Settings > Privacy > Accessibility")
      (screen-recording :purpose "ScreenCaptureKit window capture" :prompt "System Settings > Privacy > Screen Recording")))

  ;; ── Build ──────────────────────────────────────────────────

  (build
    (tool swift-package-manager)
    (commands
      (build "swift build")
      (release "swift build -c release")
      (run "swift run MacAutoBridge"))
    (output
      (debug ".build/debug/MacAutoBridge")
      (release ".build/release/MacAutoBridge")))

  ;; ── Repair Targets ─────────────────────────────────────────

  (repair-targets
    :doc "Files Mechanic may touch during auto-repair"
    ("Sources/MacAutoBridge/Server/ToolRegistry.swift"
     "Sources/MacAutoBridge/Server/MCPServer.swift"
     "Sources/MacAutoBridge/Types/SharedTypes.swift"
     "Sources/MacAutoBridge/Perception/HybridLocator.swift"
     "Sources/MacAutoBridge/Action/EventSynthesizer.swift"
     "Sources/MacAutoBridge/Transaction/TransactionRunner.swift"))
)
