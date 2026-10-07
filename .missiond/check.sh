#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
required_files=(
  ".missiond/intent.lisp"
  ".missiond/backend/mac-auto-bridge-backend-blueprint.lisp"
  ".missiond/operations/mac-auto-bridge-operations-blueprint.lisp"
  ".missiond/evidence/mac-auto-bridge-final-m6-report.lisp"
  "Sources/MacAutoBridge/main.swift"
  "Sources/MacAutoBridge/Server/MCPServer.swift"
  "Sources/MacAutoBridge/Server/ToolRouter.swift"
  "Sources/MacAutoBridge/Tools/RegisterAll.swift"
)

for rel in "${required_files[@]}"; do
  test -f "$project_root/$rel" || { echo "missing required file: $rel" >&2; exit 1; }
done

contracts="$project_root/.missiond/backend/mac-auto-bridge-backend-blueprint.lisp $project_root/.missiond/operations/mac-auto-bridge-operations-blueprint.lisp $project_root/.missiond/evidence/mac-auto-bridge-final-m6-report.lisp"
required_tokens=(domain-model policy-layer flow-layer event-contract event-bus outbox runtime-projection implementation-map code-isomorphism current-code compatibility-ledger hot-path-wiring regression-matrix final-m6-report auth-grade BoardTask worker-operational)
for token in "${required_tokens[@]}"; do
  rg -q --fixed-strings "$token" $contracts || { echo "missing required contract token: $token" >&2; exit 1; }
done

rg -q 'let server = MCPServer' "$project_root/Sources/MacAutoBridge/main.swift"
rg -q 'registerAllTools' "$project_root/Sources/MacAutoBridge/main.swift"
rg -q 'cleanStaleCoreMLTempArtifacts' "$project_root/Sources/MacAutoBridge/OCR/PaddleOCREngine.swift"
rg -q '/tmp/mac-auto-bridge-(look|capture)-' "$project_root/Sources/MacAutoBridge/Tools/Composite/LookTool.swift" "$project_root/Sources/MacAutoBridge/Tools/Composite/CaptureToFileTool.swift"

echo "mac-auto-bridge MissionD SSOT check: ok (M5; M6 blockers remain explicit)"
