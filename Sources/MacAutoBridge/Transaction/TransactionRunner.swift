import Foundation

final class TransactionRunner: @unchecked Sendable {

    static let shared = TransactionRunner()

    private let locator = LocatorEngine.shared
    private let events = EventSynthesizer.shared
    private let focus = FocusManager.shared
    private let ocr = OCRManager.shared
    private let ax = AXManager.shared

    func run(steps: [TransactionStep], bundleID: String, requiresFocusLock: Bool = true)
        async throws
    {
        if requiresFocusLock {
            _ = try await focus.acquire(bundleID: bundleID)
        }
        defer {
            if requiresFocusLock { focus.release() }
        }

        for step in steps {
            let rect = try await locator.resolve(locator: step.locator, bundleID: bundleID)
            let center = rectCenter(rect)

            switch step.action {
            case .click(let count):
                try events.click(at: center, clicks: count)
            case .typeText(let text):
                try events.typeText(text)
            case .scroll(let deltaY):
                try events.scroll(at: center, deltaY: Int32(deltaY))
            }

            if let condition = step.verify {
                try await waitForCondition(
                    condition, bundleID: bundleID,
                    timeout: step.timeout, stepName: step.name)
            }

            // Brief pause between steps
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
    }

    func waitForCondition(
        _ condition: VerificationCondition,
        bundleID: String,
        timeout: TimeInterval,
        stepName: String = "wait_until"
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            switch condition {
            case .textAppears(let text):
                let entries = try await ocr.findTextOnScreen(text: text, bundleID: bundleID)
                if !entries.isEmpty { return }

            case .textDisappears(let text):
                let entries = try await ocr.findTextOnScreen(text: text, bundleID: bundleID)
                if entries.isEmpty { return }

            case .axExists(let query):
                if (try? ax.findElement(bundleID: bundleID, query: query)) != nil {
                    return
                }

            case .windowAppears(let title):
                let windows = focus.listWindows(bundleID: bundleID)
                if windows.contains(where: { $0.title?.contains(title) == true }) {
                    return
                }
            }

            try await Task.sleep(nanoseconds: 500_000_000)  // poll every 500ms
        }

        throw BridgeError.verificationFailed(
            step: stepName, detail: "Condition not met within \(timeout)s")
    }
}
