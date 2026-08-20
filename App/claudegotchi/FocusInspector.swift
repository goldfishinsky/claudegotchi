import AppKit
import ApplicationServices
import PetCore

/// Live AX/AppKit glue behind PetCore's pure `FocusSuppression`. Reads the
/// frontmost app's focused-window title only when accessibility is already
/// trusted; it never prompts for AX from here.
enum FocusInspector {
    /// Codex Desktop owns its approval sheet itself. Bundle-ID detection does not
    /// need Accessibility permission and is enough to let our overlay yield.
    static func frontmostOwnsNativeApprovalUI() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex"
    }

    static func frontmostFocusedWindowTitle() -> String? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appEl, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
            let window = windowRef else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
            let title = titleRef as? String else { return nil }
        return title
    }

    /// True while the login screen / screensaver covers the display.
    static func screenIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// Suppress auto-expansion for `cwd` when the user is already looking at that
    /// terminal. No AX trust → no title → never suppresses.
    static func suppresses(cwd: String?) -> Bool {
        FocusSuppression.suppresses(
            axTrusted: AXIsProcessTrusted(),
            focusedWindowTitle: frontmostFocusedWindowTitle(),
            cwd: cwd)
    }
}
