import Foundation

/// Reads the user's own Herdr keybindings.
///
/// The point is that a binding says what it wants — `tab.next` — and this
/// looks up which key that currently is on *this* machine. Nobody has to
/// write `shift+right` in two places, and rebinding Herdr automatically
/// changes what the controller does.
///
/// Falls back to Herdr's documented defaults when a key is not customised.
struct Keymap {

    private var bindings: [String: String] = [:]
    private var prefix = "ctrl+a"

    /// Herdr's defaults, used when config.toml does not override them.
    private static let defaults: [String: String] = [
        "next_tab": "prefix+c",
        "previous_tab": "prefix+p",
        "next_workspace": "prefix+n",
        "previous_workspace": "prefix+p",
        "next_agent": "shift+down",
        "previous_agent": "shift+up",
        "focus_pane_left": "prefix+h",
        "focus_pane_right": "prefix+l",
        "focus_pane_up": "prefix+k",
        "focus_pane_down": "prefix+j",
        "zoom": "prefix+z",
        "split_horizontal": "prefix+\"",
        "split_vertical": "prefix+%",
        "close_pane": "prefix+x",
        "new_tab": "prefix+c",
        "new_workspace": "prefix+shift+n",
        "goto": "prefix+g",
        "last_pane": "prefix+;",
        "detach": "prefix+d",
        "toggle_sidebar": "prefix+b",
    ]

    static var configPath: String {
        if let env = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"], !env.isEmpty {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/herdr/config.toml"
    }

    static func load(path: String? = nil) -> Keymap {
        var map = Keymap()
        guard let text = try? String(contentsOfFile: path ?? configPath, encoding: .utf8),
              let root = try? TOML.parse(text),
              let keys = root.table("keys")
        else {
            return map
        }

        if let p = keys.string("prefix") { map.prefix = p }

        for (name, value) in keys {
            if let single = value as? String {
                map.bindings[name] = single
            } else if let list = value as? [Any] {
                // Several bindings can share one action, e.g.
                //   focus_pane_left = ["prefix+h", "alt+left", "ctrl+h"]
                // Prefer one without a prefix: it is a single chord, so it
                // avoids driving Herdr's two-step prefix state machine.
                let strings = list.compactMap { $0 as? String }
                map.bindings[name] = strings.first { !$0.contains("prefix") } ?? strings.first
            }
        }
        return map
    }

    /// The key spec for an action, with `prefix+` expanded into a real chord
    /// sequence (`prefix+n` → `ctrl+a n`).
    func spec(for action: String) -> String? {
        guard let raw = bindings[action] ?? Keymap.defaults[action] else { return nil }
        guard raw.hasPrefix("prefix+") else { return raw }
        return "\(prefix) \(raw.dropFirst("prefix+".count))"
    }
}
