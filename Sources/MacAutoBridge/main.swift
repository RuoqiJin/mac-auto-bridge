import Foundation
import AppKit

/// Read stdin on a dedicated thread so the main RunLoop stays free for AppKit / MainActor work.
func stdinLines() -> AsyncStream<String> {
    AsyncStream { continuation in
        Thread.detachNewThread {
            while let line = readLine() {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }
}

let server = MCPServer()

Task {
    for await line in stdinLines() {
        await server.handleLine(line)
    }
    exit(0)
}

// Keep the main thread alive — required for NSWorkspace, AX API, etc.
RunLoop.main.run()
