import Foundation
import CoreGraphics
import ApplicationServices

/// Synthesised mouse-wheel scrolling.
///
/// Herdr's socket API has no scroll method — scrollback lives in the client,
/// not the server. But Herdr *does* scroll on the mouse wheel (see
/// `mouse_scroll_lines` in its config), so posting a real wheel event gets us
/// genuine scrollback movement, which forwarding PageUp never could: those
/// keys go to the program inside the pane and do nothing at a shell prompt.
///
/// The catch is macOS permissions. Synthesising input requires Accessibility
/// approval, and the prompt names whichever process launched the daemon —
/// your terminal, not "herdr-gamepad". That surprises people, so we detect
/// the situation and say so explicitly rather than failing in silence.
enum Scroll {

    /// True when this process may post synthetic events.
    static var isPermitted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show the Accessibility prompt, once.
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Posts a wheel event. Positive scrolls up (toward older output),
    /// negative scrolls down, matching how a real wheel behaves.
    static func post(lines: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .line,
                                  wheelCount: 1,
                                  wheel1: Int32(lines),
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        // .cghidEventTap puts the event at the very start of the system's
        // input path, so the focused application receives it the same way it
        // would receive a physical wheel.
        event.post(tap: .cghidEventTap)
    }
}
