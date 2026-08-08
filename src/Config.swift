import Foundation

/// One mapped input.
struct Binding {
    enum Input {
        case button(Int)                  // standard button index
        case axis(index: Int, positive: Bool)  // stick pushed past the deadzone
        case trigger(index: Int)          // LT/RT past its threshold
    }

    let input: Input
    /// Standard button index that must be held for this binding to apply.
    /// This is what makes a two-layer ("prefix key") preset possible.
    let hold: Int?
    let action: String?
    let method: String?
    /// A Herdr keybinding action name, e.g. `next_tab`. Resolved against the
    /// user's own config.toml and sent as that key. This covers everything
    /// Herdr can already do, without a built-in per behaviour.
    let key: String?
    /// A literal key spec, e.g. `up` or `ctrl+c`, typed straight through to
    /// whatever has focus. For driving TUIs — menus, fzf, pagers — rather
    /// than Herdr itself.
    let sendKey: String?
    let params: [String: Any]
    let desc: String?
    let repeats: Bool
}

struct Config {
    var profile: Profile
    var bindings: [Binding] = []
    var deadzone: Double = 0.25
    var triggerThreshold: Double = 0.5
    var repeatDelayMs: Int = 400
    var repeatRateMs: Int = 80
    var scrollInvert = false

    /// Where a user's config lives. `HERDR_PLUGIN_CONFIG_DIR` is provided by
    /// Herdr for exactly this purpose; the fallback keeps the binary usable
    /// when run by hand outside the plugin host.
    static var configPath: String {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["HERDR_PLUGIN_CONFIG_DIR"], !dir.isEmpty {
            return "\(dir)/gamepad.toml"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/herdr/plugins/config/gamepad/gamepad.toml"
    }

    static func load(path: String? = nil) throws -> Config {
        let file = path ?? configPath
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            // A missing config is normal on first run, not an error.
            return Config(profile: .xbox360)
        }
        return try parse(try TOML.parse(text))
    }

    static func parse(_ root: [String: Any]) throws -> Config {
        var profile = Profile()

        if let pad = root.table("gamepad") {
            profile.vendorID = pad.int("vendor")
            profile.productID = pad.int("product")
            // `profile = "xbox360"` opts into the built-in table instead of
            // spelling out every usage.
            if let preset = pad.string("profile"), preset.lowercased() == "xbox360" {
                let base = Profile.xbox360
                profile.buttons = base.buttons
                profile.axes = base.axes
                profile.triggers = base.triggers
                if profile.vendorID == nil { profile.vendorID = base.vendorID }
                if profile.productID == nil { profile.productID = base.productID }
            }
        }

        // [profile.buttons]  <HID usage> = "<standard name>"
        if let table = root.table("profile")?.table("buttons") {
            for (usageKey, value) in table {
                guard let usage = UInt32(usageKey) else {
                    throw ConfigError("profile.buttons key `\(usageKey)` must be a HID usage number")
                }
                guard let name = value as? String, let index = Standard.buttonIndex(name) else {
                    throw ConfigError("profile.buttons.\(usageKey) = \(value): unknown button name. "
                                      + "Valid: \(Standard.buttonNames.joined(separator: ", "))")
                }
                profile.buttons[usage] = index
            }
        }

        // [profile.axes]  <HID axis> = "<standard axis, or lt/rt>"
        if let table = root.table("profile")?.table("axes") {
            for (axisKey, value) in table {
                guard let usage = HIDAxis.fromName(axisKey) ?? UInt32(axisKey) else {
                    throw ConfigError("profile.axes key `\(axisKey)` must be X/Y/Z/Rx/Ry/Rz or a usage number")
                }
                guard let name = (value as? String)?.lowercased() else {
                    throw ConfigError("profile.axes.\(axisKey) must be a string")
                }
                if let stick = Standard.axisIndex(name) {
                    profile.axes[usage] = stick
                } else if let button = Standard.buttonIndex(name), button == 6 || button == 7 {
                    profile.triggers[usage] = button   // analog trigger
                } else {
                    throw ConfigError("profile.axes.\(axisKey) = \"\(name)\": expected one of "
                                      + "\(Standard.axisNames.joined(separator: ", ")), lt, rt")
                }
            }
        }

        var config = Config(profile: profile)

        if let tuning = root.table("tuning") {
            config.deadzone = tuning.double("deadzone") ?? config.deadzone
            config.triggerThreshold = tuning.double("trigger_threshold") ?? config.triggerThreshold
            config.repeatDelayMs = tuning.int("repeat_delay_ms") ?? config.repeatDelayMs
            config.repeatRateMs = tuning.int("repeat_rate_ms") ?? config.repeatRateMs
            config.scrollInvert = tuning.bool("scroll_invert") ?? config.scrollInvert
        }

        // Two blocks, split by who is being talked to.
        //
        // [herdr] — operations on Herdr. Shaped exactly like Herdr's own
        // [keys] table, so the two files read the same way. A list binds
        // several inputs to one behaviour, as Herdr allows.
        if let table = root.table("herdr") {
            for (behaviour, value) in table {
                for binding in try parseKeyEntry(behaviour: behaviour, value: value) {
                    config.bindings.append(binding)
                }
            }
        }

        // [input] — pretend to be a keyboard or mouse. Nothing here goes
        // through Herdr; it drives whatever currently has focus.
        if let table = root.table("input") {
            for (behaviour, value) in table {
                let isMouse = ActionRunner.inputBuiltins.contains(behaviour)
                for binding in try parseKeyEntry(behaviour: behaviour,
                                                 value: value,
                                                 literal: !isMouse) {
                    config.bindings.append(binding)
                }
            }
        }

        // Escape hatch for anything the one-liner form cannot express
        // (hold layers, raw socket methods with params).
        for (i, entry) in root.tables("bind").enumerated() {
            config.bindings.append(try parseBinding(entry, ordinal: i + 1))
        }
        return config
    }

    /// Turns one `behaviour = input` line into bindings.
    ///
    /// With `literal: true` the left-hand side is a keystroke to type rather
    /// than a Herdr action to look up.
    private static func parseKeyEntry(behaviour: String, value: Any, literal: Bool = false) throws -> [Binding] {
        var specs: [Any] = []
        if let list = value as? [Any] { specs = list } else { specs = [value] }

        return try specs.map { spec in
            var inputName: String
            var repeats = false
            var hold: Int?

            if let name = spec as? String {
                inputName = name
            } else if let table = spec as? [String: Any] {
                guard let name = table.string("input") ?? table.string("button") else {
                    throw ConfigError("\(behaviour): table form needs input = \"...\"")
                }
                inputName = name
                repeats = table.bool("repeat") ?? false
                // A held button acts as a prefix, giving every other input a
                // second meaning — tmux's prefix idea, without needing a key
                // macOS might intercept.
                if let holdName = table.string("hold") {
                    guard let index = Standard.buttonIndex(holdName) else {
                        throw ConfigError("\(behaviour): hold = \"\(holdName)\" must be a button "
                                          + "(sticks and triggers cannot be held as a prefix)")
                    }
                    hold = index
                }
            } else {
                throw ConfigError("\(behaviour) = \(value): expected a controller input name")
            }

            guard let input = parseInput(inputName) else {
                throw ConfigError("[keys] \(behaviour) = \"\(inputName)\": unknown controller input.\n"
                    + "  buttons: \(Standard.buttonNames.joined(separator: ", "))\n"
                    + "  sticks:  left_up, left_down, left_left, left_right, "
                    + "right_up, right_down, right_left, right_right")
            }

            if literal {
                // Validate now so a typo fails at startup with a clear
                // message, not silently at 3am when you press the button.
                _ = try Keys.parse(behaviour)
                return Binding(input: input, hold: hold, action: nil, method: nil,
                               key: nil, sendKey: behaviour, params: [:],
                               desc: "type \(behaviour)", repeats: repeats)
            }

            // Anything Herdr already does is sent as its own key, so ordering
            // matches the keyboard exactly. Everything else must be a built-in.
            let isBuiltin = ActionRunner.builtinNames.contains(behaviour)
            return Binding(input: input,
                           hold: hold,
                           action: isBuiltin ? behaviour : nil,
                           method: nil,
                           key: isBuiltin ? nil : behaviour,
                           sendKey: nil,
                           params: [:],
                           desc: behaviour,
                           repeats: repeats)
        }
    }

    /// Maps a controller input name to what the daemon listens for.
    ///
    /// Triggers are analog, so `lt`/`rt` become trigger inputs rather than
    /// buttons even though the standard layout numbers them as buttons 6/7.
    static func parseInput(_ name: String) -> Binding.Input? {
        let name = name.lowercased()

        if name == "lt" { return .trigger(index: 6) }
        if name == "rt" { return .trigger(index: 7) }
        if let index = Standard.buttonIndex(name) { return .button(index) }

        // left_up / right_left / …  →  stick + direction
        let sticks: [String: (x: Int, y: Int)] = ["left": (0, 1), "right": (2, 3)]
        for (stick, axes) in sticks where name.hasPrefix(stick + "_") {
            // Pushing a stick up sends a POSITIVE value on this hardware.
            // (The W3C standard layout defines up as −1, but that is the
            // browser's normalisation, not what the HID device reports.)
            switch String(name.dropFirst(stick.count + 1)) {
            case "up":    return .axis(index: axes.y, positive: true)
            case "down":  return .axis(index: axes.y, positive: false)
            case "left":  return .axis(index: axes.x, positive: false)
            case "right": return .axis(index: axes.x, positive: true)
            default: return nil
            }
        }
        return nil
    }

    private static func parseBinding(_ entry: [String: Any], ordinal: Int) throws -> Binding {
        let where_ = "[[bind]] #\(ordinal)"

        func resolveButton(_ value: Any, field: String) throws -> Int {
            if let index = value as? Int {
                guard index >= 0, index < Standard.buttonNames.count else {
                    throw ConfigError("\(where_): \(field) = \(index) is out of range 0…16")
                }
                return index
            }
            if let name = value as? String, let index = Standard.buttonIndex(name) { return index }
            throw ConfigError("\(where_): \(field) = \(value) is not a button. "
                              + "Use a name (\(Standard.buttonNames.prefix(4).joined(separator: ", "))…) or 0…16")
        }

        let input: Binding.Input
        if let raw = entry["button"] {
            input = .button(try resolveButton(raw, field: "button"))
        } else if let raw = entry["trigger"] {
            let index = try resolveButton(raw, field: "trigger")
            guard index == 6 || index == 7 else {
                throw ConfigError("\(where_): trigger must be \"lt\" or \"rt\"")
            }
            input = .trigger(index: index)
        } else if let name = entry.string("axis") {
            guard let index = Standard.axisIndex(name) else {
                throw ConfigError("\(where_): axis = \"\(name)\" must be one of "
                                  + Standard.axisNames.joined(separator: ", "))
            }
            let direction = entry.string("direction") ?? "+"
            guard direction == "+" || direction == "-" else {
                throw ConfigError("\(where_): direction must be \"+\" or \"-\"")
            }
            input = .axis(index: index, positive: direction == "+")
        } else {
            throw ConfigError("\(where_): needs one of button / trigger / axis")
        }

        let action = entry.string("action")
        let method = entry.string("method")
        let key = entry.string("key")
        guard action != nil || method != nil || key != nil else {
            throw ConfigError("\(where_): needs one of key = \"...\", action = \"...\" or method = \"...\"")
        }
        if let action, !ActionRunner.builtinNames.contains(action) {
            throw ConfigError("\(where_): action = \"\(action)\" is not built in. "
                              + "Built-ins: \(ActionRunner.builtinNames.joined(separator: ", ")). "
                              + "For a Herdr keybinding use key = \"\(action)\"; "
                              + "for a raw socket call use method = \"\(action)\".")
        }

        var hold: Int? = nil
        if let raw = entry["hold"] { hold = try resolveButton(raw, field: "hold") }

        return Binding(input: input,
                       hold: hold,
                       action: action,
                       method: method,
                       key: key,
                       sendKey: entry.string("send_key"),
                       params: entry.table("params") ?? [:],
                       desc: entry.string("desc"),
                       repeats: entry.bool("repeat") ?? false)
    }
}

struct ConfigError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
