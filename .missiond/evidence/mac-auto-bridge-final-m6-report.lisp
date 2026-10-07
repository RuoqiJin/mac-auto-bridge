(final-m6-report
  :schema "missiond.project-final-m6-report.v1"
  :project-id mac-auto-bridge
  :source-sha "7ffce392b30b121215b5cdbd1cce5bfc091fd4e2"
  :status gap-open
  :current-maturity M5
  :target-maturity M6
  :verified [domain-model policy-layer flow-layer event-contract runtime-projection implementation-map compatibility-ledger hot-path-wiring worker-operational auth-grade]
  :regression-matrix
    [(mcp-initialize :expected "server identity and tools capability")
     (tools-list :expected "registered BridgeTool schemas")
     (ocr-memory-only :expected "OCR entries returned without durable project store")
     (onnx-temp-sweep :expected "only stale $TMPDIR/onnxruntime-* entries are removed")
     (screenshot-retention :expected "owned screenshots older than configured cutoff are removed" :status missing)
     (focus-safety :expected "write tools hold/reverify the target application focus")]
  :promotion-blockers [screenshot-retention-implementation screenshot-retention-regression codebase-source-provisioning final-independent-review]
  :claim "This report records M5 onboarding evidence and explicitly does not claim M6 completion.")
