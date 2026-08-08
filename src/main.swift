import Foundation

let usage = """
herdr-gamepad — drive Herdr with a game controller

  setup     guided mapping; writes a profile for your controller
  learn     press anything, see what it is (no config changes)
  daemon    run the mapped bindings
  status    show controller, config and daemon state

Feedback appears as Herdr notifications, because plugin actions run
without a terminal attached.
"""

let herdr = HerdrClient()
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "daemon"

/// Notifications are best-effort — Herdr rate-limits them and suppresses
/// popups for the active tab — so anything worth diagnosing also goes to the
/// log. Enable with GAMEPAD_DEBUG=1.
let debugEnabled = ProcessInfo.processInfo.environment["GAMEPAD_DEBUG"] == "1"

func debugLog(_ message: String) {
    guard debugEnabled else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(stamp)] \(message)\n".data(using: .utf8)!)
}

// A swallowed notification is the single most confusing failure mode here:
// the action ran, but the user saw nothing. Always record it.
herdr.onNotifySuppressed = { reason, title in
    debugLog("notification NOT shown (\(reason)): \(title)")
}

switch mode {
case "daemon":  runDaemon()
case "learn":   runLearn()
case "setup":   runSetup()
case "status":  runStatus()
case "-h", "--help", "help": print(usage)
default:
    FileHandle.standardError.write("unknown mode `\(mode)`\n\n\(usage)\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - daemon

func runDaemon() {
    let config: Config
    do {
        config = try Config.load()
    } catch {
        herdr.notify("Gamepad config error", body: error.localizedDescription)
        FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

    guard !config.bindings.isEmpty else {
        herdr.notify("Gamepad: no bindings",
                     body: "Copy a preset into \(Config.configPath) to get started.")
        exit(1)
    }

    let runner = ActionRunner(herdr: herdr)
    runner.scrollInvert = config.scrollInvert
    let reader = GamepadReader(profile: config.profile)

    /// Buttons currently held, so `hold = "lb"` prefixes work.
    var held = Set<Int>()
    /// Axis directions currently past the deadzone, so a held stick fires once
    /// on entry rather than continuously.
    var activeAxes = Set<String>()
    var activeTriggers = Set<Int>()
    var repeatTimers: [String: DispatchSourceTimer] = [:]

    func matches(_ binding: Binding, _ input: Binding.Input) -> Bool {
        if let hold = binding.hold, !held.contains(hold) { return false }
        // A binding without `hold` must not fire while its own prefix is held,
        // otherwise the prefix layer would trigger both layers at once.
        switch (binding.input, input) {
        case let (.button(a), .button(b)): return a == b
        case let (.trigger(a), .trigger(b)): return a == b
        case let (.axis(ai, ap), .axis(bi, bp)): return ai == bi && ap == bp
        default: return false
        }
    }

    func fire(_ input: Binding.Input, key: String) {
        let candidates = config.bindings.filter { matches($0, input) }
        // Prefer a binding that specifies `hold` — the more specific layer wins.
        guard let binding = candidates.max(by: { ($0.hold == nil ? 0 : 1) < ($1.hold == nil ? 0 : 1) })
        else {
            debugLog("\(key): no binding  held=\(held.sorted())")
            return
        }

        debugLog("\(key) → \(binding.desc ?? "?")  held=\(held.sorted()) "
                 + "candidates=\(candidates.count) hold=\(binding.hold.map(String.init) ?? "-")")
        runner.run(action: binding.action, method: binding.method, key: binding.key,
                   sendKey: binding.sendKey, params: binding.params)

        guard binding.repeats, repeatTimers[key] == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(config.repeatDelayMs),
                       repeating: .milliseconds(config.repeatRateMs))
        timer.setEventHandler {
            runner.run(action: binding.action, method: binding.method, key: binding.key,
                   sendKey: binding.sendKey, params: binding.params)
        }
        timer.resume()
        repeatTimers[key] = timer
    }

    func stopRepeat(_ key: String) {
        repeatTimers[key]?.cancel()
        repeatTimers[key] = nil
    }

    guard reader.start({ event in
        switch event {
        case let .button(index, pressed):
            let key = "b\(index)"
            if pressed {
                held.insert(index)
                fire(.button(index), key: key)
            } else {
                held.remove(index)
                stopRepeat(key)
            }

        case let .trigger(index, value):
            let on = value >= config.triggerThreshold
            if on, !activeTriggers.contains(index) {
                activeTriggers.insert(index)
                fire(.trigger(index: index), key: "t\(index)")
            } else if !on, activeTriggers.contains(index) {
                activeTriggers.remove(index)
                stopRepeat("t\(index)")
            }

        case let .axis(index, value):
            for positive in [true, false] {
                let key = "a\(index)\(positive ? "+" : "-")"
                let past = positive ? value >= config.deadzone : value <= -config.deadzone
                if past, !activeAxes.contains(key) {
                    activeAxes.insert(key)
                    fire(.axis(index: index, positive: positive), key: key)
                } else if !past, activeAxes.contains(key) {
                    activeAxes.remove(key)
                    stopRepeat(key)
                }
            }

        case .rawButton, .rawAxis:
            break  // daemon works in standard mapping only
        }
    }) else {
        herdr.notify("Gamepad not found",
                     body: "No matching controller. Run `gamepad.status` to see what is connected.")
        exit(1)
    }

    herdr.notify("Gamepad ready", body: "\(config.bindings.count) bindings active.")
    CFRunLoopRun()
}

// MARK: - learn

func runLearn() {
    // No profile filter: learn mode must see controllers we cannot yet map.
    let reader = GamepadReader(profile: Profile(), emitRaw: true)
    var lastAxisNotify: [UInt32: Date] = [:]

    guard reader.start({ event in
        switch event {
        case let .rawButton(usage, pressed) where pressed:
            let known = Profile.xbox360.buttons[usage].map { " · usually \(Standard.buttonName($0))" } ?? ""
            herdr.notify("button \(usage)", body: "pressed\(known)")

        case let .rawAxis(usage, value, min, max):
            // Sticks emit hundreds of values per second; one line per half
            // second is enough to read while still feeling responsive.
            let now = Date()
            if let last = lastAxisNotify[usage], now.timeIntervalSince(last) < 0.5 { return }
            let span = max > min ? Double(max - min) : 1
            let normalized = (Double(value - min) / span) * 2 - 1
            guard abs(normalized) > 0.4 else { return }
            lastAxisNotify[usage] = now
            herdr.notify("axis \(HIDAxis.name(usage))",
                         body: String(format: "%.2f  (raw %d, range %d…%d)", normalized, value, min, max))

        default:
            break
        }
    }) else {
        herdr.notify("Gamepad not found", body: "Plug in a controller and try again.")
        exit(1)
    }

    herdr.notify("Learn mode on", body: "Press anything. Exits after 2 minutes.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
        herdr.notify("Learn mode off")
        exit(0)
    }
    CFRunLoopRun()
}

// MARK: - status

/// Reports through both stdout and a notification: stdout is what shows up in
/// `herdr plugin log list`, the notification is what the user actually sees
/// when they invoke this as an action.
func runStatus() {
    var lines: [String] = []

    let devices = GamepadReader(profile: Profile()).connectedDevices()
    lines.append(devices.isEmpty
        ? "controller:  none detected"
        : "controller:  " + devices.joined(separator: ", "))

    let configPath = Config.configPath
    if FileManager.default.fileExists(atPath: configPath) {
        do {
            let config = try Config.load()
            lines.append("config:      \(configPath)")
            lines.append("bindings:    \(config.bindings.count)")
            lines.append("profile:     \(config.profile.buttons.count) buttons, "
                         + "\(config.profile.axes.count) axes, \(config.profile.triggers.count) triggers")
        } catch {
            lines.append("config:      INVALID — \(error.localizedDescription)")
        }
    } else {
        lines.append("config:      not found at \(configPath)")
        lines.append("             run `gamepad.setup`, then copy in a preset")
    }

    let socketOK = (try? herdr.request("ping")) != nil
    lines.append("herdr socket: \(socketOK ? "ok" : "unreachable") (\(herdr.socketPath))")

    let output = lines.joined(separator: "\n")
    print(output)
    herdr.notify(devices.isEmpty ? "Gamepad: no controller" : "Gamepad: \(devices.count) connected",
                 body: lines.dropFirst().joined(separator: " · "))
}

// MARK: - setup

/// Guided mapping. Each prompt waits for a press; anything the controller
/// cannot produce (stick clicks are missing on many clone pads) times out and
/// is skipped rather than stalling the run.
func runSetup() {
    let steps = Standard.buttonNames
    let secondsPerStep = 8.0

    let reader = GamepadReader(profile: Profile(), emitRaw: true)
    var mapping: [UInt32: Int] = [:]
    var axisMapping: [UInt32: String] = [:]
    var claimed = Set<UInt32>()
    var step = 0
    var timeoutWork: DispatchWorkItem?

    func finish() {
        timeoutWork?.cancel()
        write(buttons: mapping, axes: axisMapping)
        exit(0)
    }

    func advance() {
        timeoutWork?.cancel()
        step += 1
        if step >= steps.count {
            herdr.notify("Setup: sticks", body: "Now push both sticks and squeeze both triggers.")
            // Give the analog phase a fixed window, then write everything out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish() }
            return
        }
        prompt()
    }

    func prompt() {
        let name = steps[step]
        herdr.notify("Press: \(name.uppercased())",
                     body: "\(step + 1)/\(steps.count) · skips itself in \(Int(secondsPerStep))s if your pad lacks it")
        let work = DispatchWorkItem {
            herdr.notify("Skipped \(name.uppercased())", body: "Your controller does not report it.")
            advance()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsPerStep, execute: work)
    }

    guard reader.start({ event in
        switch event {
        case let .rawButton(usage, pressed) where pressed:
            guard step < steps.count, !claimed.contains(usage) else { return }
            claimed.insert(usage)
            mapping[usage] = step
            herdr.notify("✓ \(steps[step].uppercased()) = usage \(usage)")
            advance()

        case let .rawAxis(usage, value, min, max):
            guard step >= steps.count else { return }   // analog phase only
            let span = max > min ? Double(max - min) : 1
            let normalized = (Double(value - min) / span) * 2 - 1
            guard abs(normalized) > 0.6, axisMapping[usage] == nil else { return }
            // A trigger rests at one end of its range and only ever moves one
            // way; a stick rests centred. That is enough to tell them apart.
            let restsAtEdge = min == 0 && max == 255
            let name: String
            if restsAtEdge {
                name = axisMapping.values.contains("lt") ? "rt" : "lt"
            } else {
                let assigned = axisMapping.values.filter { Standard.axisIndex($0) != nil }.count
                name = Standard.axisNames[Swift.min(assigned, Standard.axisNames.count - 1)]
            }
            axisMapping[usage] = name
            herdr.notify("✓ \(HIDAxis.name(usage)) = \(name)")

        default:
            break
        }
    }) else {
        herdr.notify("Gamepad not found", body: "Plug in a controller and run setup again.")
        exit(1)
    }

    herdr.notify("Setup started", body: "Follow the prompts. \(steps.count) buttons, then the sticks.")
    prompt()
    CFRunLoopRun()
}

func write(buttons: [UInt32: Int], axes: [UInt32: String]) {
    var out = """
    # Written by `gamepad.setup` — your controller's own translation table.
    # Left side is the raw HID usage your hardware sends; right side is the
    # W3C standard-gamepad name, which is what presets and [[bind]] refer to.

    [profile.buttons]

    """
    for (usage, index) in buttons.sorted(by: { $0.value < $1.value }) {
        out += "\(usage) = \"\(Standard.buttonName(index))\"\n"
    }
    out += "\n[profile.axes]\n"
    for (usage, name) in axes.sorted(by: { $0.key < $1.key }) {
        out += "\(HIDAxis.name(usage)) = \"\(name)\"\n"
    }

    let path = Config.configPath.replacingOccurrences(of: "gamepad.toml", with: "profile.toml")
    do {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try out.write(toFile: path, atomically: true, encoding: .utf8)
        herdr.notify("Setup complete",
                     body: "\(buttons.count) buttons, \(axes.count) axes → profile.toml. "
                           + "Merge it into gamepad.toml and pick a preset.")
    } catch {
        herdr.notify("Setup could not save", body: error.localizedDescription)
    }
}
