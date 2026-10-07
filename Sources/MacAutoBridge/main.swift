import Foundation
import AppKit

func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    fputs(line, stderr)
}

/// Read stdin on a dedicated thread so the main RunLoop stays free for AppKit / MainActor work.
func stdinLines() -> AsyncStream<String> {
    AsyncStream { continuation in
        Thread.detachNewThread {
            log("stdin reader thread started")
            while let line = readLine() {
                log("stdin message received (\(line.utf8.count) bytes)")
                continuation.yield(line)
            }
            log("stdin EOF")
            continuation.finish()
        }
    }
}

log("MacAutoBridge starting, pid=\(ProcessInfo.processInfo.processIdentifier), ppid=\(getppid())")

// ── Bootstrap: Subsystem Gates ──
let axGate = AXGate()
let captureGate = CaptureGate()
let inputGate = InputGate()
let healthMonitor = HealthMonitor(ax: axGate, capture: captureGate)

let ctx = ToolContext(
    ax: axGate,
    capture: captureGate,
    input: inputGate,
    health: healthMonitor
)

// ── Bootstrap: Tool Router ──
let router = ToolRouter()
registerAllTools(router)

log("Registered \(router.listTools().count) tools")

// ── Bootstrap: MCP Server ──
let server = MCPServer(router: router, ctx: ctx)

Task {
    // Start health monitor
    await healthMonitor.start()
    log("HealthMonitor started (3s tick)")

    for await line in stdinLines() {
        await server.handleLine(line)
    }
    log("stdin loop ended, exiting")
    exit(0)
}

// Keep the main thread alive — required for NSWorkspace, AX API, etc.
RunLoop.main.run()
