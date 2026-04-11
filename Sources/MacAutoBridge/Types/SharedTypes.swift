import Foundation
import CoreGraphics

// MARK: - AX Types

struct AXNode: Sendable {
    let role: String
    let subrole: String?
    let title: String?
    let identifier: String?
    let frame: CGRect
    let children: [AXNode]

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = ["role": role, "frame": frameToDict(frame)]
        if let s = subrole { dict["subrole"] = s }
        if let t = title { dict["title"] = t }
        if let i = identifier { dict["identifier"] = i }
        if !children.isEmpty { dict["children"] = children.map { $0.toJSON() } }
        return dict
    }
}

struct AXQuery: Sendable {
    let role: String?
    let title: String?
    let identifier: String?

    init(role: String? = nil, title: String? = nil, identifier: String? = nil) {
        self.role = role
        self.title = title
        self.identifier = identifier
    }

    init(from dict: [String: Any]) {
        self.role = dict["role"] as? String
        self.title = dict["title"] as? String
        self.identifier = dict["identifier"] as? String
    }

    func matches(_ node: AXNode) -> Bool {
        if let r = role, node.role != r { return false }
        if let t = title, node.title != t { return false }
        if let i = identifier, node.identifier != i { return false }
        return true
    }
}

// MARK: - OCR Types

struct OCRTextEntry: Sendable {
    let text: String
    let frame: CGRect       // screen-global coordinates
    let confidence: Float

    func toJSON() -> [String: Any] {
        ["text": text, "frame": frameToDict(frame), "confidence": confidence]
    }
}

// MARK: - Display Types

struct DisplayInfo: Sendable {
    let displayID: UInt32
    let bounds: CGRect
    let scale: CGFloat

    func toJSON() -> [String: Any] {
        ["display_id": displayID, "bounds": frameToDict(bounds), "scale": scale]
    }
}

// MARK: - Window Types

struct WindowInfo: Sendable {
    let windowID: UInt32
    let title: String?
    let bundleID: String?
    let frame: CGRect
    let isOnScreen: Bool

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = [
            "window_id": windowID,
            "frame": frameToDict(frame),
            "is_on_screen": isOnScreen,
        ]
        if let t = title { dict["title"] = t }
        if let b = bundleID { dict["bundle_id"] = b }
        return dict
    }
}

// MARK: - Target Locator

enum TargetLocator: Sendable {
    case ax(AXQuery)
    case ocr(String)
    case coordinate(CGPoint)

    init(from dict: [String: Any]) {
        if let axDict = dict["ax"] as? [String: Any] {
            self = .ax(AXQuery(from: axDict))
        } else if let text = dict["ocr"] as? String {
            self = .ocr(text)
        } else if let x = dict["x"] as? Double, let y = dict["y"] as? Double {
            self = .coordinate(CGPoint(x: x, y: y))
        } else {
            self = .coordinate(.zero)
        }
    }
}

// MARK: - Transaction Types

enum VerificationCondition: Sendable {
    case textAppears(String)
    case textDisappears(String)
    case axExists(AXQuery)
    case windowAppears(String)
}

struct TransactionStep: Sendable {
    let name: String
    let locator: TargetLocator
    let action: ActionKind
    let verify: VerificationCondition?
    let timeout: TimeInterval
}

enum ActionKind: Sendable {
    case click(count: Int)
    case typeText(String)
    case scroll(deltaY: Double)
}

// MARK: - Errors

enum BridgeError: Error, LocalizedError {
    case focusLost(expected: String, actual: String?)
    case elementNotFound(String)
    case verificationFailed(step: String, detail: String)
    case transactionAborted(step: String, reason: String)
    case accessibilityDenied
    case screenCaptureDenied
    case timeout(TimeInterval)
    case appNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .focusLost(let exp, let act):
            "Focus lost: expected '\(exp)', got '\(act ?? "nil")'"
        case .elementNotFound(let desc):
            "Element not found: \(desc)"
        case .verificationFailed(let step, let detail):
            "Verification failed at '\(step)': \(detail)"
        case .transactionAborted(let step, let reason):
            "Transaction aborted at '\(step)': \(reason)"
        case .accessibilityDenied:
            "Accessibility permission denied — grant in System Settings > Privacy > Accessibility"
        case .screenCaptureDenied:
            "Screen capture permission denied — grant in System Settings > Privacy > Screen Recording"
        case .timeout(let secs):
            "Timed out after \(secs)s"
        case .appNotRunning(let bundle):
            "App not running: \(bundle)"
        }
    }
}

// MARK: - Helpers

func frameToDict(_ rect: CGRect) -> [String: Any] {
    ["x": rect.origin.x, "y": rect.origin.y, "width": rect.size.width, "height": rect.size.height]
}

func rectCenter(_ rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
}
