import AppKit
import Foundation

/// Periodic health monitor for subsystem gates.
/// Runs a background tick every 3 seconds, probing AX status and
/// draining the capture queue when the system is unrecoverable.
actor HealthMonitor {

    struct SystemHealth: Sendable {
        var ax: AXGate.Health
        var systemBlocker: String?
    }

    private let ax: AXGate
    private let capture: CaptureGate
    private var tickTask: Task<Void, Never>?
    private var latest: SystemHealth = SystemHealth(ax: .healthy, systemBlocker: nil)

    init(ax: AXGate, capture: CaptureGate) {
        self.ax = ax
        self.capture = capture
    }

    // MARK: - Lifecycle

    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Query

    func status() -> SystemHealth {
        latest
    }

    // MARK: - Tick

    private func tick() async {
        let axHealth = await ax.probe()
        let blocker = detectSystemBlocker()

        latest = SystemHealth(ax: axHealth, systemBlocker: blocker)

        // If AX is dead, drain capture queue — screenshots without AX
        // context are nearly useless and will pile up.
        switch axHealth {
        case .dead:
            await capture.drain()
            fputs("[HealthMonitor] AX dead — capture queue drained\n", stderr)
        case .degraded(let reason):
            fputs("[HealthMonitor] AX degraded: \(reason)\n", stderr)
        case .healthy:
            break
        }

        if let blocker {
            fputs("[HealthMonitor] System blocker: \(blocker)\n", stderr)
        }
    }

    // MARK: - System Blocker Detection

    /// Check for TCC permission dialogs or other system-level blockers.
    func detectSystemBlocker() -> String? {
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard let bid = app.bundleIdentifier else { continue }
            if bid == "com.apple.universalaccessAuthWarn" {
                return "Accessibility permission dialog (universalAccessAuthWarn)"
            }
            if bid == "com.apple.tccd" {
                return "TCC daemon dialog active"
            }
        }
        return nil
    }
}
