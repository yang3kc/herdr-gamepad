import Foundation

let usage = """
herdr-gamepad — drive Herdr with a game controller

  setup     guided mapping; writes a profile for your controller
  learn     press anything, see what it is (no config changes)
  daemon    run the mapped bindings
  status    show controller, config and daemon state
  rumble    play a haptic pattern on the pad: rumble [off|single|double|triple|long]

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
    infoLog(message)
}

/// Always written. Used for the rare, worth-keeping lines: haptics events.
func infoLog(_ message: String) {
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
case "rumble":  runRumble()
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

    // MARK: prefix layers
    //
    // A prefix can be reached two ways, and both are live at once:
    //
    //   hold  — keep it down and press the second button, as before
    //   tap   — press and release it alone; the next input goes to the layer
    //
    // Tapping needs no new config: the prefix buttons are exactly the ones some
    // binding already names in `hold`, so any existing preset gains this.

    /// Buttons some binding uses as a `hold` prefix.
    let prefixButtons = Set(config.bindings.compactMap(\.hold))
    /// The prefix that was tapped and is waiting for its second button.
    var armed: Int?
    var armedTimer: DispatchSourceTimer?
    /// Prefixes whose current press has already done its job — it opened a hold
    /// layer, or it cancelled an armed one. Releasing them must not arm.
    var prefixConsumed = Set<Int>()
    /// Whether Herdr is sitting in prefix mode because we put it there.
    ///
    /// The pad's prefix button sends Herdr's own prefix chord, so the mode is
    /// real and visible rather than a state this daemon keeps to itself. Herdr's
    /// prefix is one-shot, so this drops the moment a key spends it — and it is
    /// what keeps Escape from ever being sent blind into a pane.
    var herdrPrefixLive = false

    func enterHerdrPrefix() {
        guard !herdrPrefixLive else { return }
        runner.enterPrefixMode()
        herdrPrefixLive = true
        debugLog("herdr prefix mode: entered")
    }

    func leaveHerdrPrefix() {
        guard herdrPrefixLive else { return }
        runner.leavePrefixMode()
        herdrPrefixLive = false
        debugLog("herdr prefix mode: left")
    }

    func disarm() {
        armedTimer?.cancel()
        armedTimer = nil
        armed = nil
    }

    /// Drops an armed prefix *and* closes Herdr's, for the paths where nothing
    /// is going to spend it.
    func cancelPrefix() {
        disarm()
        leaveHerdrPrefix()
    }

    func arm(_ index: Int) {
        guard config.prefixTimeoutMs > 0 else {
            // Tap-to-arm is off, so this press opened nothing. Herdr's prefix
            // must not be left hanging over the keyboard.
            leaveHerdrPrefix()
            return
        }
        disarm()
        armed = index
        let name = Standard.buttonName(index)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(config.prefixTimeoutMs))
        timer.setEventHandler {
            debugLog("prefix \(name) expired unused")
            armed = nil
            armedTimer = nil
            leaveHerdrPrefix()
        }
        timer.resume()
        armedTimer = timer

        debugLog("prefix \(name) armed for \(config.prefixTimeoutMs)ms")
        if config.prefixNotify {
            herdr.notify("Gamepad: \(name)", body: "Prefix armed — press the next button.")
        }
    }

    func matches(_ binding: Binding, _ input: Binding.Input) -> Bool {
        // A hold layer is reachable either by physically holding the prefix or
        // by having tapped it a moment ago.
        if let hold = binding.hold, !held.contains(hold), armed != hold { return false }
        // A binding without `hold` must not fire while its own prefix is held,
        // otherwise the prefix layer would trigger both layers at once.
        switch (binding.input, input) {
        case let (.button(a), .button(b)): return a == b
        case let (.trigger(a), .trigger(b)): return a == b
        case let (.axis(ai, ap), .axis(bi, bp)): return ai == bi && ap == bp
        default: return false
        }
    }

    /// Sends one binding with Herdr in the prefix state that binding needs.
    ///
    /// The two layers want opposite things. A prefix-layer binding needs Herdr
    /// waiting in prefix mode, so only the tail of its chord goes out. A base-
    /// layer one needs it *not* to be waiting, or its key gets swallowed by a
    /// prefix it never asked for.
    func deliver(_ binding: Binding) {
        if binding.hold != nil {
            enterHerdrPrefix()
            runner.run(action: binding.action, method: binding.method, key: binding.key,
                       sendKey: binding.sendKey, params: binding.params, inPrefixMode: true)
            // Herdr's prefix is one-shot, and that key just spent it.
            herdrPrefixLive = false
        } else {
            leaveHerdrPrefix()
            runner.run(action: binding.action, method: binding.method, key: binding.key,
                       sendKey: binding.sendKey, params: binding.params)
        }
    }

    /// A held pad prefix outlives Herdr's one-shot one, so re-open it: the next
    /// press in the layer still lands, and the mode stays visible meanwhile.
    func reopenHeldPrefix(_ binding: Binding) {
        guard let hold = binding.hold, held.contains(hold) else { return }
        enterHerdrPrefix()
    }

    func fire(_ input: Binding.Input, key: String) {
        let candidates = config.bindings.filter { matches($0, input) }
        // Prefer a binding that specifies `hold` — the more specific layer wins.
        guard let binding = candidates.max(by: { ($0.hold == nil ? 0 : 1) < ($1.hold == nil ? 0 : 1) })
        else {
            debugLog("\(key): no binding  held=\(held.sorted()) armed=\(armed.map(String.init) ?? "-")")
            // An armed prefix is spent by whatever comes next, even an input the
            // layer says nothing about. Leaving it armed would silently apply it
            // to some later, unrelated press — and leaving Herdr's open would
            // eat the next thing typed at the keyboard.
            cancelPrefix()
            return
        }

        debugLog("\(key) → \(binding.desc ?? "?")  held=\(held.sorted()) "
                 + "armed=\(armed.map(String.init) ?? "-") "
                 + "candidates=\(candidates.count) hold=\(binding.hold.map(String.init) ?? "-")")

        if let hold = binding.hold, held.contains(hold) {
            // Reached by holding: releasing the prefix now ends a hold, and
            // must not be mistaken for a tap.
            prefixConsumed.insert(hold)
        }
        // Either this used the armed prefix, or it fell through to the base
        // layer while one was armed. Both spend it.
        disarm()

        deliver(binding)
        reopenHeldPrefix(binding)

        guard binding.repeats, repeatTimers[key] == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(config.repeatDelayMs),
                       repeating: .milliseconds(config.repeatRateMs))
        timer.setEventHandler {
            deliver(binding)
            reopenHeldPrefix(binding)
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
                guard prefixButtons.contains(index) else {
                    fire(.button(index), key: key)
                    break
                }
                // A prefix button never fires an action of its own: with both
                // tap and hold live, "what did that press mean" has to have one
                // answer, and it is always "open the layer".
                if armed == index {
                    // Tapping an armed prefix again backs out of it.
                    debugLog("prefix \(Standard.buttonName(index)) cancelled")
                    cancelPrefix()
                    prefixConsumed.insert(index)
                } else {
                    prefixConsumed.remove(index)
                    // Herdr enters prefix mode now, on the press. That is the
                    // whole point: the mode shows up the moment your thumb
                    // lands, exactly as it does for ctrl+a.
                    enterHerdrPrefix()
                }
            } else {
                held.remove(index)
                stopRepeat(key)
                if prefixButtons.contains(index) {
                    // Released without having opened a layer → it was a tap,
                    // and Herdr stays in prefix mode until the tap is spent.
                    if !prefixConsumed.contains(index) {
                        arm(index)
                    } else if armed == nil {
                        // A spent hold, or a cancel. Nothing is waiting on
                        // Herdr's prefix now, so close it.
                        leaveHerdrPrefix()
                    }
                    prefixConsumed.remove(index)
                }
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

        case .rawButton, .rawAxis, .rawHat:
            break  // daemon works in standard mapping only
        }
    }) else {
        herdr.notify("Gamepad not found",
                     body: "No matching controller. Run `gamepad.status` to see what is connected.")
        exit(1)
    }

    // Rumble on agent status changes. Its own HerdrClient, because the
    // watcher polls on a background queue and the shared client is not
    // built for two threads.
    var haptics: Haptics?
    var watcher: AgentWatcher?
    if config.haptics.enabled {
        let h = Haptics()
        h.onLog = infoLog
        let w = AgentWatcher(herdr: HerdrClient(socketPath: herdr.socketPath),
                             haptics: h, settings: config.haptics)
        w.onLog = infoLog
        w.start()
        haptics = h
        watcher = w
    }

    herdr.notify("Gamepad ready",
                 body: "\(config.bindings.count) bindings active"
                       + (config.haptics.enabled ? ", rumble on." : "."))
    withExtendedLifetime((haptics, watcher)) {
        CFRunLoopRun()
    }
}

// MARK: - learn

func runLearn() {
    // No profile filter: learn mode must see controllers we cannot yet map.
    let reader = GamepadReader(profile: Profile(), emitRaw: true)
    var lastAxisNotify: [UInt32: Date] = [:]

    guard reader.start({ event in
        switch event {
        case let .rawButton(usage, page, pressed) where pressed:
            let known = page == HIDPage.button
                ? Profile.xbox360.buttons[usage].map { " · usually \(Standard.buttonName($0))" } ?? ""
                : " · \(HIDPage.name(page)) page"
            herdr.notify("button \(usage)", body: "pressed\(known)")

        case let .rawAxis(usage, page, value, min, max):
            // Sticks emit hundreds of values per second; one line per half
            // second is enough to read while still feeling responsive.
            let now = Date()
            if let last = lastAxisNotify[usage], now.timeIntervalSince(last) < 0.5 { return }
            let span = max > min ? Double(max - min) : 1
            let normalized = (Double(value - min) / span) * 2 - 1
            guard abs(normalized) > 0.4 else { return }
            lastAxisNotify[usage] = now
            let where_ = page == HIDPage.genericDesktop ? "" : " (\(HIDPage.name(page)) page)"
            herdr.notify("axis \(HIDAxis.name(usage))\(where_)",
                         body: String(format: "%.2f  (raw %d, range %d…%d)", normalized, value, min, max))

        case let .rawHat(value, min, max):
            let hat = Hat.decode(raw: value, min: min, max: max)
            guard hat != Hat() else { return }
            herdr.notify("hat switch \(value)", body: "\(hat.label) · decoded as dpad_* automatically")

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
                         + "\(config.profile.axes.count) axes, \(config.profile.triggers.count) triggers "
                         + "(a hat-switch D-pad is decoded without a profile entry)")
            let h = config.haptics
            lines.append("haptics:     " + (h.enabled
                ? "on — blocked=\(h.blocked.rawValue), done=\(h.done.rawValue), poll \(h.pollMs) ms"
                  + (h.ignoreFocused ? ", focused pane ignored" : "")
                : "off ([haptics] enabled = true turns it on)"))
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

// MARK: - rumble

/// `herdr-gamepad rumble [pattern]` — play one pattern and exit. The quickest
/// way to check that the pad's motors answer from this machine at all.
func runRumble() {
    let name = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "double"
    guard let pattern = HapticPattern(rawValue: name) else {
        FileHandle.standardError.write("unknown pattern `\(name)`; use one of: \(HapticPattern.names)\n".data(using: .utf8)!)
        exit(2)
    }
    let haptics = Haptics()
    haptics.onLog = { print($0) }
    // Pairing is already done; the framework just needs a few run-loop turns
    // to hand us the controller.
    let deadline = Date().addingTimeInterval(3)
    while !haptics.isReady, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard haptics.isReady else {
        print("no controller with haptics found (is the pad awake? press the Xbox button)")
        exit(1)
    }
    haptics.play(pattern)
    print("playing \(pattern.rawValue)")
    RunLoop.main.run(until: Date().addingTimeInterval(pattern.totalDuration + 0.5))
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
        case let .rawButton(usage, _, pressed) where pressed:
            guard step < steps.count, !claimed.contains(usage) else { return }
            claimed.insert(usage)
            mapping[usage] = step
            herdr.notify("✓ \(steps[step].uppercased()) = usage \(usage)")
            advance()

        case let .rawHat(value, min, max):
            // The whole D-pad arrived as one hat switch. It needs no entry in
            // the profile, so skip its four prompts instead of timing out on
            // each.
            guard step < steps.count, Hat.decode(raw: value, min: min, max: max) != Hat() else { return }
            let dpadSteps = 12...15
            guard dpadSteps.contains(step) else { return }
            timeoutWork?.cancel()
            herdr.notify("✓ D-pad is a hat switch", body: "Decoded automatically — skipping its four steps.")
            step = dpadSteps.upperBound + 1
            if step >= steps.count { advance() } else { prompt() }

        case let .rawAxis(usage, _, value, min, max):
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
