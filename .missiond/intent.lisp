;; ============================================================
;; MacAutoBridge — Intent Declaration
;; Generated: 2026-04-11 | Updated: 2026-04-12 | Forge Deep Cartography v3
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
;; 7787627: capture_to_file — screenshot-only PNG (no OCR), saves Codex 2-call pattern
;; f125c64: context_menu_click + watch_progress — data-driven from Codex op analysis
;; c7ece94: app-level SCK capture composites ALL app windows (popups, context menus)
;; 556638d: watch_progress two-phase + scrollUntilText auto-shorten for OCR line breaks
;; 776615a: captureOnly() — zero Vision calls, capture_to_file now <1s (was 12 min)
;; ff05459: focus.verify() auto re-acquires on drift — focus-transparent for agents
;; 0936695: every action calls ensureActive() first — unconditional proactive focus grab
;; cfe41da: CaptureSerializer actor + get_selection tool + watch_progress 90s cap
;; 3c50ee5: look tool (composite: file_path+ax_tree+ocr_entries) + right_click returns menu
;; f19521c: look OCR 8s wall-clock timeout with graceful degradation → ocr_skipped:true
;; 8b75304: remove stalled detection from watch_progress — false positives on subtitle recognition
;; e0d9a65: 100s wall-clock guard on ALL MCP tool calls in MCPServer
;; xxxxxxx: export_srt one-click tool + subtitle_workflow rewrite (open -R / Cmd+E / SCK warm-up)

(intent mac-auto-bridge
  (granularity L3-implementation)

  (design-constraints
    (constraint zero-deps
      :rule "No external SPM dependencies — pure Apple frameworks only"
      :evidence "Package.swift has no .package() entries")
    (constraint focus-safety
      :rule "Every write action proactively grabs focus before execution via ensureActive(); verify() auto re-acquires on drift"
      :evidence "EventSynthesizer all methods call ensureActive() then verify(); FocusManager.verify() silently re-activates on drift")
    (constraint focus-transparent
      :rule "Agents never need to explicitly manage focus — every action tool handles it unconditionally"
      :evidence "ensureActive() no-op if already frontmost; verify() never throws unless app not running")
    (constraint screen-global-coords
      :rule "All coordinates in screen-global space, auto-scaled for Retina + multi-display"
      :evidence "OCRManager transforms window-local → global; DisplayManager tracks scale factors")
    (constraint singleton-managers
      :rule "Thread-safe shared instances for all managers (@unchecked Sendable)"
      :evidence "FocusManager.shared, AXManager.shared, OCRManager.shared, LocatorEngine.shared")
    (constraint async-first
      :rule "All I/O is async/await, no blocking on main thread"
      :evidence "main.swift: stdin on detached thread, RunLoop.main.run() for AppKit")
    (constraint capture-serialized
      :rule "All ScreenCaptureKit + Vision OCR entry points serialized through CaptureSerializer actor"
      :evidence "CaptureSerializer.swift — Swift actor + per-call timeout prevents concurrent SCK deadlocks")
    (constraint tool-wall-clock-guard
      :rule "Every MCP tool call has a 100s wall-clock guard — returns clean error instead of getting killed by client"
      :evidence "MCPServer.withToolTimeout() wraps every tools/call dispatch"))

  ;; ── Pillar 1: Perception (Read-Only Sensors) ──────────────

  (pillar perception
    :purpose "Read-only observation of macOS UI state via AX + OCR + display topology"

    (component ax-observer
      :target "Sources/MacAutoBridge/Perception/AXObserver.swift"
      :doc "Accessibility API tree builder — snapshotApp/snapshotFocusedWindow/findElement/performAction/getFocusedElementValue/getSelection"
      :struct "AXManager"
      :capabilities (snapshot-app snapshot-focused-window find-element find-elements perform-action get-focused-element-value find-pid get-selection)
      :limits (max-depth 10 default-depth 5)
      :note "getFocusedElementValue: reads kAXValueAttribute of focused UI element — used by typeInFocusedField for AX-first input verification"
      :get-selection (
        :method "getSelection(bundleID:) — reads AXSelected / AXSelectedChildren / AXSelectedRows from focused window"
        :purpose "Agent asks OS 'what's selected' instead of guessing from screenshot")
      :app-discovery (
        :primary "NSWorkspace.shared.runningApplications (reliable in MCP child process context)"
        :fallback "NSRunningApplication.runningApplications(withBundleIdentifier:)"
        :reason "MCP child processes have different process context — NSRunningApplication direct lookup may fail"))

    (component vision-ocr
      :target "Sources/MacAutoBridge/Perception/VisionOCR.swift"
      :doc "Vision Framework OCR + ScreenCaptureKit window/display capture — two capture modes"
      :struct "OCRManager"
      :capabilities (capture-and-recognize capture-only find-text-on-screen recognize-text select-best-window)
      :languages ("zh-Hans" "zh-Hant" "en-US")
      :recognition-level ".fast (was .accurate — changed for speed on complex UIs like 剪映)"
      :language-correction false
      :coordinate-transform "window-local → screen-global with Retina scaling + per-display origin offset"
      :capture-modes (
        (capture-and-recognize :doc "SCK capture + Vision OCR — returns OCRResult with text entries" :used-by "snapshot, look, watch_progress, scroll_until_text")
        (capture-only :doc "SCK capture with ZERO Vision calls — returns raw CGImage instantly" :used-by "capture_to_file" :perf "<1s vs 12min with OCR"))
      :app-level-capture (
        :trigger "windowTitle not specified"
        :method "SCContentFilter(display:including:[app]) composites ALL app windows"
        :purpose "Popups, dialogs, context menus (separate macOS windows) now visible"
        :crop "union bounding box of all app windows for OCR performance"
        :single-window-fallback "SCContentFilter(desktopIndependentWindow:) when windowTitle is specified")
      :window-selection (
        :method "selectBestWindow — private helper replacing .first(where:)"
        :filters (on-screen-only layer-0-only min-size-50px)
        :rank "title match first, then largest area (width×height)")
      :multi-display (
        :behavior "findTextOnScreen scans ALL displays in content.displays, not just first"
        :transform "displayBounds.origin + entry.frame/scale for each display"
        :failure-mode "skip display on capture error, aggregate results across all"))

    (component capture-serializer
      :target "Sources/MacAutoBridge/Perception/CaptureSerializer.swift"
      :doc "Swift actor serializing all SCK + Vision OCR calls — prevents concurrent deadlocks"
      :struct "CaptureSerializer"
      :note "actor CaptureSerializer — all captureAndRecognize/captureOnly entry points routed through this"
      :per-call-timeout true)

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
      :doc "App focus acquisition/verification/release — 4s timeout, aggressive strategy, auto re-acquire on drift"
      :struct "FocusManager"
      :capabilities (focus-app acquire verify release ensure-active list-windows current-bundle-id)
      :focus-strategy (
        :stage-1 "NSRunningApplication.activate(.activateIgnoringOtherApps) — 2s timeout"
        :stage-2 "AppleScript 'tell application id ... to activate' — 2s additional"
        :total-timeout "4s"
        :reason "activate() alone can't beat Chrome holding focus in real-world testing")
      :verify-behavior (
        :drift-detection "Detects if focused app drifted between acquire and event synthesis"
        :auto-reacquire "Silently re-activates locked app: activate() → 1s → AppleScript fallback → 0.5s"
        :only-throws "App no longer running")
      :ensure-active (
        :method "ensureActive() — unconditional best-effort activation before every event synthesis"
        :fast-path "No-op if already frontmost (zero overhead)"
        :slow-path "activate() + 200ms wait"
        :never-throws true)
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
      :list-windows-discovery "PID→bundleID map from NSWorkspace + stderr diagnostics")

    (component event-synthesizer
      :target "Sources/MacAutoBridge/Action/EventSynthesizer.swift"
      :doc "CGEvent mouse click/drag/scroll + keyboard typeText/pressKey — proactive focus before every call"
      :struct "EventSynthesizer"
      :capabilities (click drag scroll type-text press-key)
      :safety "All methods call ensureActive() then verify() — focus-transparent to agents"
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
    :purpose "High-level composite methods — simplified API for common automation patterns"

    (component mvp-facade
      :target "Sources/MacAutoBridge/Transaction/MVPFacade.swift"
      :doc "focus-and-assert / capture-app / click-text / type-in-focused-field / snapshot / goto-folder / capture-to-file / context-menu-click / watch-progress / look / right-click / scroll-until-text"
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
          :note "Designed for 剪映/Finder Go-To-Folder dialogs")
        (capture-to-file
          :doc "Screenshot-only PNG — NO OCR. Saves PNG and returns path."
          :params ((bundle_id String :required) (window_title String) (file_path String))
          :uses "captureOnly() — zero Vision calls, <1s"
          :motivation "Codex called exec_command(screencapture)+view_image 56 times — now 1 call")
        (context-menu-click
          :doc "Right-click target → wait for menu → click menu item in ONE call"
          :params ((bundle_id String :required) (target_text String) (menu_item String :required)
                   (target_ax_role String) (target_ax_title String) (target_ax_id String))
          :ax-path "AX query ~5x faster than OCR (300ms vs 1.5s), OCR fallback"
          :motivation "Codex: right_click → snapshot → click(AXMenuItem) = 4 calls → 1 call")
        (right-click
          :doc "Right-click at target location, returns {menu_appeared, menu_items}"
          :params ((bundle_id String :required) (target_* various))
          :post-click "polls AX up to 400ms for AXMenu — no screenshot needed to verify")
        (watch-progress
          :doc "Poll OCR every 2s until progress indicator disappears. Returns done:true or still_running:true."
          :params ((bundle_id String :required) (disappears String :required) (timeout Float))
          :timeout-cap "110s internal cap (Codex MCP kills at 120s)"
          :two-phase "First wait for indicator to APPEAR (15s), then wait for DISAPPEAR"
          :consecutive-checks "2 consecutive gone-checks to avoid OCR flicker"
          :no-stalled-detection "Removed — subtitle recognition routinely freezes at same % for 30-60s (false positives)"
          :still-running-behavior "Call again, NEVER cancel or re-trigger original action")
        (look
          :doc "Composite: file_path + ax_tree + ocr_entries in ONE call. Replaces capture_to_file + snapshot + view_image triple."
          :params ((bundle_id String :required) (file_path String) (include_ocr Boolean :default true))
          :returns "{ file_path, ax_tree, ocr_entries[], duration_ms, ocr_skipped? }"
          :ocr-timeout "8s wall-clock — degrades to capture-only (ocr_skipped:true) if stalls"
          :motivation "~18 occurrences of 3-call pattern in 100 Codex calls → 1 call")
        (scroll-until-text
          :doc "Scroll until target text is visible via OCR"
          :auto-shorten "shortenForOCR() extracts key segment (e.g. 'ep104') from long filenames — OCR breaks long filenames across lines"))))

  ;; ── Pillar 5: Server (MCP JSON-RPC 2.0) ───────────────────

  (pillar server
    :purpose "JSON-RPC 2.0 over stdio — MCP protocol implementation"

    (component mcp-server
      :target "Sources/MacAutoBridge/Server/MCPServer.swift"
      :doc "JSON-RPC request dispatcher — initialize/ping/tools-list/tools-call + 100s wall-clock guard"
      :struct "MCPServer"
      :protocol-version "2024-11-05"
      :wall-clock-guard (
        :method "withToolTimeout() wraps every tools/call dispatch"
        :timeout "100s — universal safety net"
        :on-exceed "Returns clean error response (step: tool_timeout) instead of silent client kill"
        :note "Individual tools may have tighter timeouts (look: 8s OCR, watch_progress: 110s)"))

    (component tool-registry
      :target "Sources/MacAutoBridge/Server/ToolRegistry.swift"
      :doc "26 tool definitions + dispatch logic"
      :struct "ToolRegistry"
      :tool-count 27
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

  ;; ── MCP Tools (26 total) ───────────────────────────────────

  (tools
    :doc "26 MCP tools exposed via JSON-RPC 2.0 (all guarded by 100s wall-clock)"

    ;; Perception (7)
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
    (tool get_selection :category perception :focus-lock none
      :params ((bundle_id String :required))
      :doc "Reads AXSelected/AXSelectedChildren/AXSelectedRows from focused window — agent asks OS 'what's selected'")

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

    ;; MVP Facade (13)
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
    (tool capture_to_file :category mvp :focus-lock none
      :params ((bundle_id String :required) (window_title String) (file_path String))
      :doc "Screenshot-only PNG (no OCR) — fast <1s. Replaces screencapture shell workaround.")
    (tool right_click :category mvp :focus-lock acquire-release
      :params ((bundle_id String :required)
               (target_ax_role String) (target_ax_title String) (target_ax_id String)
               (target_ocr String) (target_x Float) (target_y Float))
      :doc "Right-click at target, returns {menu_appeared, menu_items} — polls AX 400ms for AXMenu")
    (tool context_menu_click :category mvp :focus-lock acquire-release
      :params ((bundle_id String :required)
               (target_text String) (menu_item String :required)
               (target_ax_role String) (target_ax_title String) (target_ax_id String))
      :doc "Right-click target → wait for menu → click item. AX path preferred (~5x faster than OCR).")
    (tool watch_progress :category mvp :focus-lock none
      :params ((bundle_id String :required) (disappears String :required) (timeout Float))
      :doc "Poll OCR every 2s until indicator gone. done:true = act now. still_running:true = call again, NEVER cancel."
      :timeout-cap "110s internal")
    (tool look :category mvp :focus-lock none
      :params ((bundle_id String :required) (file_path String) (include_ocr Boolean :default true))
      :doc "Composite: PNG save + AX tree + OCR entries. OCR has 8s timeout (degrades to ocr_skipped:true). Returns duration_ms."
      :returns "{ file_path, ax_tree, ocr_entries[], duration_ms, ocr_skipped? }")
    (tool scroll_until_text :category mvp :focus-lock acquire-release
      :params ((bundle_id String :required) (text String :required) (direction String) (timeout Float))
      :doc "Scroll until text visible in OCR. Auto-shortens long filenames for OCR line-break robustness.")
    (tool drag :category mvp :focus-lock acquire-release
      :params ((bundle_id String :required) (from_x Float :required) (from_y Float :required)
               (to_x Float :required) (to_y Float :required))
      :doc "Click-drag from one coordinate to another")

    ;; Domain Workflow (2)
    (tool subtitle_workflow :category workflow :focus-lock acquire-release
      :params ((bundle_id String) (mp3_path String :required) (output_dir String) (episode_name String :required))
      :timeout "600s"
      :doc "Full subtitle pipeline: import MP3 via Finder drag → create timeline → recognize → wait → export SRT → rename. SCK warm-up + open -R + AX selection for drag coords."
      :data-driven "Codex op logs 2026-04-12: open -R replaces OCR file search, Cmd+E replaces OCR export button, AX getSelection for drag source")
    (tool export_srt :category workflow :focus-lock acquire-release
      :params ((bundle_id String) (episode_name String :required) (output_dir String))
      :timeout "30s"
      :doc "One-call SRT export: Cmd+E → export dialog → ExportOkBtn → wait completion → rename → close. Replaces 6-8 manual calls.")

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
     "Sources/MacAutoBridge/Perception/VisionOCR.swift"
     "Sources/MacAutoBridge/Perception/AXObserver.swift"
     "Sources/MacAutoBridge/Perception/CaptureSerializer.swift"
     "Sources/MacAutoBridge/Action/FocusManager.swift"
     "Sources/MacAutoBridge/Action/EventSynthesizer.swift"
     "Sources/MacAutoBridge/Transaction/MVPFacade.swift"
     "Sources/MacAutoBridge/Transaction/TransactionRunner.swift"))
)
