import Foundation
import CoreGraphics

/// Bulkhead actor isolating ScreenCaptureKit + Vision OCR.
/// Serializes capture operations (same tail-chain as CaptureSerializer)
/// and adds drain() to flush the queue when the system is unhealthy.
///
/// Two-tier OCR:
///   Tier 1: Apple Vision (fast, every screenshot)
///   Tier 2: PP-OCRv5 via ONNX Runtime (when Vision confidence is low)
actor CaptureGate {

    private let ocr = OCRManager()
    private let paddleOCR: PaddleOCREngine?
    private var tail: Task<Void, Never>?
    private var draining = false

    private let defaultTimeout: TimeInterval = 12

    /// Confidence threshold below which Tier 2 (PaddleOCR) is invoked
    private let tier2Threshold: Float = 0.5

    init() {
        // PaddleOCR is optional — if models are missing, Tier 2 is simply unavailable
        do {
            self.paddleOCR = try PaddleOCREngine()
            fputs("[CaptureGate] PP-OCRv5 Tier 2 engine loaded\n", stderr)
        } catch {
            self.paddleOCR = nil
            fputs("[CaptureGate] PP-OCRv5 unavailable. Tier 1 only.\n", stderr)
        }
    }

    // MARK: - Capture + OCR

    func captureAndRecognize(
        bundleID: String,
        windowTitle: String? = nil,
        fast: Bool = false
    ) async throws -> (CGImage, [OCRTextEntry]) {
        try await serialized(timeout: fast ? 10 : defaultTimeout) { [ocr] in
            try await ocr._captureAndRecognize(
                bundleID: bundleID, windowTitle: windowTitle, fast: fast)
        }
    }

    // MARK: - Capture Only

    func captureOnly(
        bundleID: String,
        windowTitle: String? = nil
    ) async throws -> CGImage {
        try await serialized(timeout: 10) { [ocr] in
            try await ocr._captureOnly(bundleID: bundleID, windowTitle: windowTitle)
        }
    }

    // MARK: - Text Search (Two-Tier)

    func findTextOnScreen(
        text: String,
        bundleID: String? = nil
    ) async throws -> [OCRTextEntry] {
        let keywords = text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        if let bid = bundleID {
            // Tier 1: Apple Vision
            let (image, entries) = try await captureAndRecognize(bundleID: bid)
            let matched = entries.filter { entry in
                keywords.contains { entry.text.localizedCaseInsensitiveContains($0) }
            }

            // If Vision found results with good confidence, return immediately
            let avgConfidence = matched.isEmpty ? 0 : matched.map(\.confidence).reduce(0, +) / Float(matched.count)
            if !matched.isEmpty && avgConfidence >= tier2Threshold {
                return matched
            }

            // Tier 2: PP-OCRv5 fallback (if available and Vision didn't find enough)
            // Tier 2 failure is NON-FATAL — always fall back to Tier 1 results.
            if let paddle = paddleOCR {
                fputs("[CaptureGate] Tier 2 fallback: Vision avg confidence \(avgConfidence), trying PP-OCRv5\n", stderr)
                do {
                    let paddleEntries = try paddle.recognize(image: image)
                    let paddleMatched = paddleEntries.filter { entry in
                        keywords.contains { entry.text.localizedCaseInsensitiveContains($0) }
                    }
                    if paddleMatched.count > matched.count {
                        return paddleMatched
                    }
                } catch {
                    fputs("[CaptureGate] Tier 2 failed (non-fatal)\n", stderr)
                }
            }

            return matched
        }

        // All-displays scan (Tier 1 only — no image available for Tier 2)
        return try await serialized(timeout: 20) { [ocr] in
            try await ocr._findTextOnScreenAllDisplays(text: text)
        }
    }

    // MARK: - Direct PP-OCR Access

    /// Run PP-OCRv5 directly on an image (for tools that want explicit Tier 2)
    func recognizeWithPaddleOCR(image: CGImage) throws -> [OCRTextEntry]? {
        try paddleOCR?.recognize(image: image)
    }

    // MARK: - Drain

    /// Force-clear the queue. All pending waiters receive a timeout error.
    func drain() {
        draining = true
        tail?.cancel()
        tail = nil
        // Reset after a tick so new requests can flow again
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            await self?.resetDrain()
        }
    }

    private func resetDrain() {
        draining = false
    }

    // MARK: - Serializer

    private func serialized<T: Sendable>(
        timeout: TimeInterval,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        if draining {
            throw BridgeError.timeout(0)
        }

        let prev = tail
        let task = Task<T, Error> {
            if let prev { _ = await prev.value }
            if Task.isCancelled || draining {
                throw BridgeError.timeout(0)
            }
            return try await withDeadline(seconds: timeout, step: "capture_gate", work)
        }
        tail = Task<Void, Never> {
            _ = try? await task.value
        }
        return try await task.value
    }
}
