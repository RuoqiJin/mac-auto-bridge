#!/usr/bin/env python3
"""Check MCP payloads stay on stdout and never enter diagnostic stderr."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
marker = "PRIVACY_REGRESSION_SENTINEL"
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": marker, "method": "ping"},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
     "params": {"name": marker, "arguments": {"text": marker}}},
]
result = subprocess.run(
    [str(root / ".build/debug/MacAutoBridge")], cwd=root,
    input="\n".join(json.dumps(r) for r in requests) + "\n{\"" + marker + "\n",
    text=True, capture_output=True, timeout=60, check=True,
)
responses = {r["id"]: r for r in map(json.loads, result.stdout.splitlines())}
assert responses[1]["result"]["serverInfo"]["name"] == "MacAutoBridge"
assert len(responses[2]["result"]["tools"]) == 28
assert responses[marker]["result"] == {}
assert responses[4]["result"]["isError"] is True
assert marker not in result.stderr, "Request/response content leaked into stderr"
assert "stdin message received" in result.stderr, "Expected payload-free diagnostics"
assert "stdout response sent" in result.stderr, "Expected payload-free diagnostics"
print("PASS: initialize, 28 tools, ping, unknown tool and malformed input; no payload in stderr")
