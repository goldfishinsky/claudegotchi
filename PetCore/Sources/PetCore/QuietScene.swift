import Foundation

/// Pure decision for "the screen is being recorded or shared, keep quiet". The App
/// supplies the live signals (CoreGraphics display-capture state and the frontmost
/// app's bundle id); this keeps the policy testable and permission-free.
public enum QuietScene {
    /// Best-effort fallback: apps that, when frontmost, usually mean an active
    /// screen share or recording. Display capture is the primary signal; this only
    /// catches ScreenCaptureKit-based tools that don't flip the capture flag.
    public static let captureAppBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.obsproject.obs-studio",
        "com.apple.QuickTimePlayerX",
        "com.techsmith.screenflow",
        "com.loom.desktop",
    ]

    public static func isActive(
        displayCaptured: Bool,
        frontmostBundleID: String?,
        captureAppBundleIDs: Set<String> = QuietScene.captureAppBundleIDs
    ) -> Bool {
        if displayCaptured { return true }
        if let id = frontmostBundleID, captureAppBundleIDs.contains(id) { return true }
        return false
    }
}
