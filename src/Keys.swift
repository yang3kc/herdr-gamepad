import Foundation
import CoreGraphics

/// Synthesises keyboard shortcuts.
///
/// This exists because Herdr already knows how to do most of what you want.
/// It has `next_agent`, `next_tab`, `focus_pane_right` and so on, each with
/// ordering logic that matches what you see on screen. Reimplementing that
/// ordering over the socket API produced a sequence that looked random.
///
/// Sending Herdr's own shortcut sidesteps the problem entirely: the behaviour
/// is identical to pressing the key yourself, by construction.
///
/// Like scrolling, this needs Accessibility permission.
enum Keys {

    /// US-layout virtual key codes. Only the keys people actually bind to a
    /// controller are here; unknown names fail loudly at config-parse time
    /// rather than silently doing nothing at 3am.
    private static let codes: [String: CGKeyCode] = [
        "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,  "z": 6,  "x": 7,
        "c": 8,  "v": 9,  "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25, "0": 29,
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "pageup": 116, "pagedown": 121, "home": 115, "end": 119,
        // Punctuation, because Herdr binds to it: `prefix+;` for last_pane,
        // `prefix+minus` for split_horizontal. Herdr spells that one as a
        // word, so both forms are here.
        ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50,
        "-": 27, "minus": 27, "=": 24, "[": 33, "]": 30, "\\": 42,
    ]

    /// Symbols that are themselves a shifted key on a US layout.
    ///
    /// A binding writes the symbol it means — Herdr's `help = "prefix+?"` —
    /// not `shift+/`. The shift therefore has to come from the character
    /// rather than from the modifier list.
    private static let shifted: [String: CGKeyCode] = [
        "?": 44, ":": 41, "\"": 39, "<": 43, ">": 47, "~": 50,
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22,
        "&": 26, "*": 28, "(": 25, ")": 29,
        "_": 27, "{": 33, "}": 30, "|": 42,
    ]

    private static let modifiers: [String: CGEventFlags] = [
        "shift": .maskShift,
        "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "cmd": .maskCommand, "command": .maskCommand, "super": .maskCommand,
    ]

    struct Chord {
        let code: CGKeyCode
        let flags: CGEventFlags
    }

    /// Parses `"shift+right"`, or a space-separated sequence such as
    /// `"ctrl+a n"` for Herdr's prefix bindings.
    static func parse(_ spec: String) throws -> [Chord] {
        try spec.split(separator: " ").map { part in
            var flags = CGEventFlags()
            var keyName: String?
            for piece in part.split(separator: "+") {
                let token = piece.lowercased()
                if let modifier = modifiers[token] {
                    flags.insert(modifier)
                } else {
                    keyName = token
                }
            }
            guard let keyName else {
                throw ConfigError("key spec `\(part)` has modifiers but no key")
            }
            if let code = codes[keyName] {
                return Chord(code: code, flags: flags)
            }
            if let code = shifted[keyName] {
                return Chord(code: code, flags: flags.union(.maskShift))
            }
            throw ConfigError("unknown key `\(keyName)` in `\(spec)`. "
                              + "Known: letters, digits, arrows, punctuation, "
                              + "return, tab, space, escape, delete, pageup, pagedown, home, end")
        }
    }

    static func send(_ chords: [Chord]) {
        let source = CGEventSource(stateID: .hidSystemState)
        for chord in chords {
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source,
                                          virtualKey: chord.code,
                                          keyDown: isDown) else { continue }
                event.flags = chord.flags
                event.post(tap: .cghidEventTap)
            }
            // Herdr's prefix bindings are a two-step state machine; firing the
            // second chord instantly can beat it into that state.
            if chords.count > 1 {
                usleep(20_000)  // 20ms
            }
        }
    }
}
