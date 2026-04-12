import Foundation

/// Serializes ScreenCaptureKit + Vision OCR calls. SCK can deadlock or
/// stall when multiple capture pipelines run concurrently against the same
/// process; the registry observed snapshot+capture_to_file each blocking
/// for 2-3 minutes before the Codex MCP client killed them at 120s.
///
/// Each work item runs strictly after the previous completes, with a hard
/// per-call timeout so a stuck SCK call cannot poison the queue.
actor CaptureSerializer {

    static let shared = CaptureSerializer()

    private var tail: Task<Void, Never>?

    func run<T: Sendable>(
        timeout: TimeInterval = 10,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let prev = tail
        let task = Task<T, Error> {
            if let prev = prev { _ = await prev.value }
            return try await Self.withTimeout(seconds: timeout, work)
        }
        // Update tail to a waiter that swallows errors so the chain never breaks.
        tail = Task<Void, Never> {
            _ = try? await task.value
        }
        return try await task.value
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BridgeError.verificationFailed(
                    step: "capture_serializer",
                    detail: "Capture call exceeded \(Int(seconds))s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
