import Foundation
import AppKit

let logFile = FileHandle(forWritingAtPath: "/tmp/mac-auto-bridge.log")
    ?? { FileManager.default.createFile(atPath: "/tmp/mac-auto-bridge.log", contents: nil)
        return FileHandle(forWritingAtPath: "/tmp/mac-auto-bridge.log")! }()

func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    fputs(line, stderr)
    logFile.seekToEndOfFile()
    logFile.write(line.data(using: .utf8)!)
}

/// Read stdin on a dedicated thread so the main RunLoop stays free for AppKit / MainActor work.
func stdinLines() -> AsyncStream<String> {
    AsyncStream { continuation in
        Thread.detachNewThread {
            log("stdin reader thread started")
            while let line = readLine() {
                log("stdin << \(line.prefix(200))")
                continuation.yield(line)
            }
            log("stdin EOF")
            continuation.finish()
        }
    }
}

log("MacAutoBridge starting, pid=\(ProcessInfo.processInfo.processIdentifier), ppid=\(getppid())")

let server = MCPServer()

Task {
    for await line in stdinLines() {
        await server.handleLine(line)
    }
    log("stdin loop ended, exiting")
    exit(0)
}

// Keep the main thread alive — required for NSWorkspace, AX API, etc.
RunLoop.main.run()
