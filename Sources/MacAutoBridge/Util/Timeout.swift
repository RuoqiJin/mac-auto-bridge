import Foundation

/// Unified deadline-based timeout. Replaces the 3 duplicated withTimeout
/// implementations in MCPServer, CaptureSerializer, and MVPFacade.
///
/// Key difference from the old pattern: callers should check Task.isCancelled
/// in their async work to cooperate with cancellation. The old pattern raced
/// two tasks but never actually cancelled the work task — it just abandoned it.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    step: String = "deadline",
    _ op: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw BridgeError.verificationFailed(
                step: step,
                detail: "exceeded \(Int(seconds))s wall-clock limit")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
