import AppKit
import CoreGraphics
import PetCore

/// Live glue behind PetCore's pure `QuietScene`. Detects an active screen
/// recording / share without requesting any new permission, plus lock/sleep, so
/// callers get one "keep quiet" answer.
///
/// `CGDisplayIsCaptured` is the permission-free capture flag that still works on
/// macOS 14/15, but recent SDK headers mark it unavailable — so it is resolved at
/// runtime via `dlsym` and simply skipped where the symbol is gone. A best-effort
/// frontmost-app heuristic covers ScreenCaptureKit tools that leave the flag unset.
enum QuietSceneInspector {
    private typealias DisplayIsCapturedFn = @convention(c) (CGDirectDisplayID) -> Int32
    private static let displayIsCaptured: DisplayIsCapturedFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayIsCaptured") else { return nil }
        return unsafeBitCast(sym, to: DisplayIsCapturedFn.self)
    }()

    static func anyDisplayCaptured() -> Bool {
        guard let fn = displayIsCaptured else { return false }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { fn($0) != 0 }
    }

    @MainActor
    static func isActive(settings: SettingsStore) -> Bool {
        if settings.quietOnLock && FocusInspector.screenIsLocked() { return true }
        guard settings.quietOnCapture else { return false }
        return QuietScene.isActive(
            displayCaptured: anyDisplayCaptured(),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
