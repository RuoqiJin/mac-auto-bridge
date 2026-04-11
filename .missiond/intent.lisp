;; ============================================================
;; MacAutoBridge — Intent Declaration
;; Generated: 2026-04-11 | Updated: 2026-04-11 | Forge Deep Cartography v3
;; ============================================================
;; State-aware macOS GUI Automation MCP Server
;; Pure Swift, zero external dependencies
;; 5-pillar architecture: Perception / Action / Transaction / Facade / Server
;; macOS 14+ | Swift 5.10+ | MCP JSON-RPC 2.0 over stdio
;; cc997cc: 5 real-world fixes — WindowRanker / multi-display OCR / WindowFilter /
;;          AX-value verification / pretty-printed JSON
;; 1de5e17: robust app discovery for MCP child processes + diagnose tool
;; ede7689: aggressive focus (AppleScript fallback 4s) + CGWindowList title fallback
;; fe968a8: snapshot + goto_folder composite tools (−60% tool calls)
;; 7edfa14: snapshot default fast mode (no OCR) + OCR .accurate→.fast

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
      :doc "Accessibility API tree builder — snapshotApp/snapshotFocusedWindow/findElement/performAction/getFocusedElementValue"
      :struct "AXManager"
      :capabilities (snapshot-app snapshot-focused-window find-element find-elements perform-action get-focused-element-value find-pid)
      :limits (max-depth 10 default-depth 5)
      :note "getFocusedElementValue: reads kAXValueAttribute of focused UI element — used by typeInFocusedField for AX-first input verification"
      :app-discovery (
        :primary "NSWorkspace.shared.runningApplications (reliable in MCP child process context)"
        :fallback "NSRunningApplication.runningApplications(withBundleIdentifier:)"
        :reason "MCP child processes have different process context — NSRunningApplication direct lookup may fail"))

    (component vision-ocr
      :target "Sources/MacAutoBridge/Perception/VisionOCR.swift"
      :doc "Vision Framework OCR + ScreenCaptureKit window/display capture"
      :struct "OCRManager"
      :capabilities (capture-and-recognize find-text-on-screen recognize-text select-best-window)
      :languages ("zh-Hans" "zh-Hant" "en-US")
      :recognition-level ".fast (was .accurate — changed for speed on complex UIs like 剪映)"
      :language-correction false
      :coordinate-transform "window-local → screen-global with Retina scaling + per-display origin offset"
      :window-selection (
        :method "selectBestWindow — private helper replacing .first(where:)"
        :filters (on-screen-only layer-0-only min-size-50px)
        :rank "title match first, then largest area (width×height)")
      :multi-display (
        :behavior "findTextOnScreen scans ALL displays in content.displays, not just first"
        :transform "displayBounds.origin + entry.frame/scale for each display"
        :failure-mode "skip display on capture error, aggregate results across all"))

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
      :doc "App focus acquisition/verification/release — 4s timeout, aggressive strategy"
      :struct "FocusManager"
      :capabilities (focus-app acquire verify release list-windows current-bundle-id)
      :focus-strategy (
        :stage-1 "NSRunningApplication.activate(.activateIgnoringOtherApps) — 2s timeout"
        :stage-2 "AppleScript 'tell application id ... to activate' — 2s additional"
        :total-timeout "4s"
        :reason "activate() alone can't beat Chrome holding focus in real-world testing")
      :window-title-verify (
        :primary "AX focused window title"
        :fallback "CGWindowList title matching"
        :reason "System modals (save/open panels) return nil AX title — CGWindowList catches these")
      :window-filter (
        :when "bundleID == nil (list all windows)"
        :rules (layer-must-be-0 min-size-50px skip-system-bundles)
        :system-bundles-blocked (
          "com.apple.controlcenter"
          "com.apple.notificationcenterui"
          "com.apple.WindowManager"
          "com.apple.dock"
          "com.apple.SystemUIServer"))
      :list-windows-discovery "PID→bundleID map from NSWorkspace + stderr diagnostics"))

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
    :purpose "6 high-level methods — simplified API for common automation patterns"

    (component mvp-facade
      :target "Sources/MacAutoBridge/Transaction/MVPFacade.swift"
      :doc "focus-and-assert / capture-app / click-text / type-in-focused-field / snapshot / goto-folder"
      :struct "MVPFacade"
      :methods (
        (focus-and-assert :doc "Activate app + optional window title verify")
        (capture-app :doc "Screenshot + OCR → {width, height, entries[]}")
        (click-text :doc "OCR-find text → click center → verify focus")
        (type-in-focused-field
          :doc "Type into focused field → two-stage verification"
          :verification-strategy (
            (stage-1 :method "AX value (getFocusedElementValue)" :delay "300ms" :priority primary
              :note "Exact, no false positives — works for native text fields")
            (stage-2 :method "OCR fallback (findTextOnScreen)" :delay "+200ms" :priority fallback
              :note "For non-standard fields: web views, canvas, custom inputs"))
          :error-detail "checked AX value + OCR")
        (snapshot
          :doc "Composite: windows + focused AX tree + optional OCR in ONE call"
          :params ((bundle_id String :required) (include_ocr Boolean :default false))
          :returns "{ windows[], ax_tree, ocr_entries[]? }"
          :impact "−60% tool calls for observation workflows"
          :note "Default fast mode (no OCR) — OCR adds significant latency on complex UIs")
        (goto-folder
          :doc "Composite: Cmd+Shift+G → type path → Enter in ONE call"
          :params ((bundle_id String :required) (path String :required))
          :impact "−60% tool calls for file dialog navigation"
          :note "Designed for 剪映/Finder Go-To-Folder dialogs"))))

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
      :doc "18 tool definitions + dispatch logic"
      :struct "ToolRegistry"
      :tool-count 18
      :json-output "prettyPrinted + sortedKeys — JSONSerialization options for LLM readability"))

  ;; ── Entry Point ────────────────────────────────────────────

  (component entry
    :target "Sources/MacAutoBridge/main.swift"
    :doc "Detached stdin reader → async JSON-RPC loop + RunLoop.main.run() + stderr logging"
    :threading "stdin on detached thread, AppKit/AX/CGEvent on main"
    :stderr-logging "Startup diagnostics: pid, parent_pid, NSWorkspace app count, CGWindowList count, AX trusted")

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
    :doc "18 MCP tools exposed via JSON-RPC 2.0"

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

    ;; MVP Facade (6)
    (tool focus_and_assert :category mvp :focus-lock none
      :params ((bundle_id String :required) (window_title String)))
    (tool capture_app :category mvp :focus-lock none
      :params ((bundle_id String :required)))
    (tool click_text :category mvp :focus-lock acquire-release
      :params ((bundle_id String :required) (text String :required) (nth Integer)))
    (tool type_in_focused_field :category mvp :focus-lock acquire-release
      :params ((bundle_id String :required) (text String :required) (verify Boolean)))
    (tool snapshot :category mvp :focus-lock none
      :params ((bundle_id String :required) (include_ocr Boolean :default false))
      :doc "Composite: windows + AX tree + optional OCR in one call")
    (tool goto_folder :category mvp :focus-lock acquire-release
      :params ((bundle_id String :required) (path String :required))
      :doc "Composite: Cmd+Shift+G → type path → Enter")

    ;; Diagnostic (1)
    (tool diagnose :category diagnostic :focus-lock none
      :doc "Debug tool: reports pid, parent_pid, NSWorkspace app count, CGWindowList count, AX trusted status"))

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
