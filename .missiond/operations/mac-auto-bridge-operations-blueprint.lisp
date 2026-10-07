(mac-auto-bridge-operations-blueprint
  :schema "missiond.project-operations-blueprint.v1"
  :project-id mac-auto-bridge
  :deployment local-only
  :source-provider github
  :canonical-remote "https://github.com/RuoqiJin/mac-auto-bridge.git"
  :production-domain none
  :database none
  :auth "MCP host spawn authority plus macOS Accessibility and Screen Recording TCC grants"

  (artifact-lifecycle-policy
    :ocr-results (:persistence memory-only :retention "request lifetime" :delete-api not-applicable)
    :screenshots (:paths ["/tmp/mac-auto-bridge-look-*.png" "/tmp/mac-auto-bridge-capture-*.png"]
                  :recommended-retention "24 hours"
                  :hard-maximum "7 days"
                  :current-auto-prune missing)
    :onnx-coreml-temp (:path "$TMPDIR/onnxruntime-*"
                       :retention "30 minutes after last modification"
                       :current-auto-prune "PaddleOCREngine init best-effort sweep")
    :mcp-host-logs (:owner external-mcp-host
                    :path-pattern "~/Library/Caches/claude-cli-nodejs/*/mcp-logs-mac-auto-bridge/*.jsonl"
                    :recommended-retention "7 days or 50 MiB total, whichever is reached first"
                    :bridge-delete-authority none)
    :privacy "Screenshots and OCR text may contain private on-screen content; retention defaults must be short and deletion must be bounded to owned filename prefixes.")

  (function local-build-and-run
    :entry [source-tree macos-14 swift-5.10]
    :core ((step s1 :logic "Run the read-only project SSOT checker.")
           (step s2 :logic "Build with Swift Package Manager on the local Mac.")
           (step s3 :logic "Configure the resulting executable as an MCP stdio child and grant TCC permissions to the actual host process."))
    :egress [local-binary mcp-server]
    :surfaces ["Package.swift" "README.md" ".missiond/check.sh"]
    :runtime-projection (runtime macos deployment local-process))

  (function temporary-artifact-maintenance
    :entry [current-time retention-policy]
    :core ((step s1 :logic "Enumerate only bridge-owned screenshot prefixes and ONNX Runtime temp prefixes.")
           (step s2 :logic "Exclude files newer than their class cutoff and never follow caller-supplied broad paths.")
           (step s3 :logic "Delete bounded stale artifacts and report counts/bytes without logging OCR contents."))
    :egress [temporary-artifact-pruned maintenance-report]
    :surfaces ["Sources/MacAutoBridge/OCR/PaddleOCREngine.swift"
               "Sources/MacAutoBridge/Tools/Composite/LookTool.swift"
               "Sources/MacAutoBridge/Tools/Composite/CaptureToFileTool.swift"]
    :runtime-projection (status partial screenshot-auto-prune missing))

  (worker-operational
    :BoardTask-required true
    :write-rule "Workers require an accepted shard, explicit write scope, and must-not-touch scope before changing Swift or MissionD SSOT."
    :exclusive-operations [screen-control keyboard-input mouse-input tcc-dialog]
    :parallel-safe [read-only-review static-check disk-inventory])

  (current-state
    :live local-only
    :known-gaps [temp-screenshot-auto-prune retention-regression-tests codebase-source-provisioning final-m6-promotion-evidence]
    :production-mutation none))
