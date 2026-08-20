import AppKit
import CoreGraphics
import PetCore

/// Permission-free context for the floating pet. We intentionally inspect only
/// public geometry/owner metadata, never window titles or screen pixels.
@MainActor
final class DesktopEnvironmentSensor {
    private let frameProvider: () -> NSRect?
    private let onUpdate: (PetEnvironment) -> Void
    private var timer: Timer?
    private var lastCursor: NSPoint?
    private var lastSampleDate: Date?
    private var lastWindowSignature: UInt64?
    private var windowEventID: Int64?
    private var sampleCount = 0

    init(frameProvider: @escaping () -> NSRect?, onUpdate: @escaping (PetEnvironment) -> Void) {
        self.frameProvider = frameProvider
        self.onUpdate = onUpdate
    }

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastCursor = nil
        lastSampleDate = nil
    }

    private func sample() {
        guard let frame = frameProvider() else { return }
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let cursor = NSEvent.mouseLocation
        let elapsed = max(0.05, now.timeIntervalSince(lastSampleDate ?? now.addingTimeInterval(-0.5)))
        let speed: Double
        if let lastCursor {
            speed = hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y) / elapsed
        } else {
            speed = 0
        }
        lastCursor = cursor
        lastSampleDate = now

        let center = NSPoint(x: frame.midX, y: frame.midY)
        let distance = hypot(cursor.x - center.x, cursor.y - center.y)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let edgeInset: CGFloat = 34
        let nearEdge = frame.minX <= visible.minX + edgeInset
            || frame.maxX >= visible.maxX - edgeInset
            || frame.minY <= visible.minY + edgeInset
            || frame.maxY >= visible.maxY - edgeInset

        sampleCount += 1
        if sampleCount == 1 || sampleCount % 6 == 0 {
            let signature = windowSignature()
            if let previous = lastWindowSignature, previous != signature { windowEventID = nowMs }
            lastWindowSignature = signature
        }

        let keyboardIdle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown)
        let mouseIdle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .mouseMoved)
        let clickIdle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .leftMouseDown)
        let userIdle = min(keyboardIdle, mouseIdle, clickIdle)

        onUpdate(PetEnvironment(
            isDesktop: true,
            cursorDistance: Double(distance),
            cursorSpeed: speed,
            nearScreenEdge: nearEdge,
            windowEventID: windowEventID,
            localHour: Calendar.current.component(.hour, from: now),
            userIdleSeconds: userIdle.isFinite ? userIdle : 0
        ))
    }

    private func windowSignature() -> UInt64 {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return 0 }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let rows = raw.compactMap { info -> String? in
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            guard layer == 0, pid != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any]
            else { return nil }
            let x = (bounds["X"] as? NSNumber)?.intValue ?? 0
            let y = (bounds["Y"] as? NSNumber)?.intValue ?? 0
            let w = (bounds["Width"] as? NSNumber)?.intValue ?? 0
            let h = (bounds["Height"] as? NSNumber)?.intValue ?? 0
            return "\(pid):\(x):\(y):\(w):\(h)"
        }.sorted()
        return GenomeRNG.fnv1a64(rows.joined(separator: "|"))
    }
}
