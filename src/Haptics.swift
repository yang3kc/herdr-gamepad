import Foundation
import GameController
import CoreHaptics

/// A rumble: on/off lengths in milliseconds, on first (`[300, 150, 300]` is
/// two 0.3 s pulses with a 0.15 s gap). Named presets cover the usual cases.
struct HapticPattern: Equatable {
    /// Alternating on, off, on, off… in ms. A trailing off is ignored.
    var steps: [Int]
    /// Preset name or the literal steps, for logs.
    var name: String

    static let presets: [(name: String, steps: [Int])] = [
        ("off",    []),
        ("single", [350]),
        ("double", [300, 150, 300]),
        ("triple", [200, 120, 200, 120, 200]),
        ("long",   [800]),
    ]

    static var names: String { presets.map(\.name).joined(separator: ", ") }

    static func named(_ name: String) -> HapticPattern? {
        guard let p = presets.first(where: { $0.name == name }) else { return nil }
        return HapticPattern(steps: p.steps, name: p.name)
    }

    /// Accepts a preset name, `"300,150,300"` (the CLI form) or a TOML array
    /// of ms (`[300, 150, 300]`). Nil when it is none of those.
    static func parse(_ value: Any) -> HapticPattern? {
        if let s = value as? String {
            if let p = named(s) { return p }
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let ms = parts.compactMap { Int($0) }
            guard !parts.isEmpty, ms.count == parts.count else { return nil }
            return fromSteps(ms)
        }
        if let arr = value as? [Any] {
            let ms = arr.compactMap { ($0 as? Int) ?? (($0 as? Double).map { Int($0) }) }
            guard ms.count == arr.count else { return nil }
            return fromSteps(ms)
        }
        return nil
    }

    private static func fromSteps(_ ms: [Int]) -> HapticPattern? {
        guard ms.allSatisfy({ $0 >= 0 }), ms.reduce(0, +) <= 10_000 else { return nil }
        return HapticPattern(steps: ms, name: "[" + ms.map(String.init).joined(separator: ", ") + "]")
    }

    var isOff: Bool { pulses.isEmpty }

    /// Pulses as (start offset, length) in seconds.
    var pulses: [(start: TimeInterval, duration: TimeInterval)] {
        var out: [(TimeInterval, TimeInterval)] = []
        var t: TimeInterval = 0
        for (i, ms) in steps.enumerated() {
            let secs = TimeInterval(ms) / 1000
            if i % 2 == 0, ms > 0 { out.append((t, secs)) }
            t += secs
        }
        return out
    }

    /// How long the whole pattern takes to play out.
    var totalDuration: TimeInterval {
        pulses.map { $0.start + $0.duration }.max() ?? 0
    }
}

/// Drives the pad's motors through Apple's GameController framework.
///
/// Input stays on IOKit (Gamepad.swift); this is a second, output-only view
/// of the same pad. The framework is a client of macOS's own game-controller
/// service, which holds the pad whether or not this daemon runs, so it does
/// not compete with the IOKit reader for the device.
///
/// Everything here runs on the main thread: the connect/disconnect
/// notifications arrive there, and `play` expects to be called there.
final class Haptics {

    enum HapticsError: LocalizedError {
        case noController
        var errorDescription: String? { "no controller with haptics is connected" }
    }

    /// Which motors play, by config name. On an Xbox pad `left_handle` is the
    /// heavy low-frequency motor, `right_handle` the light one, `triggers`
    /// the two impulse triggers; `all` is everything at once.
    static let localities: [(name: String, locality: GCHapticsLocality)] = [
        ("handles",      .handles),
        ("left_handle",  .leftHandle),
        ("right_handle", .rightHandle),
        ("triggers",     .triggers),
        ("all",          .all),
    ]
    static var localityNames: String { localities.map(\.name).joined(separator: ", ") }
    static func locality(named name: String) -> GCHapticsLocality? {
        localities.first(where: { $0.name == name })?.locality
    }
    static func isLocalityName(_ name: String) -> Bool { locality(named: name) != nil }

    /// Motor strength of every pulse, 0…1.
    var intensity: Float = 1.0
    /// CoreHaptics sharpness, 0…1. What it does on a given pad is the pad's
    /// business; expose it so people can try.
    var sharpness: Float = 0.5
    /// Which motors, by name from `localities`.
    var localityName = "handles" {
        didSet { if localityName != oldValue { dropEngine() } }
    }
    var onLog: ((String) -> Void)?

    private var controller: GCController?
    private var engine: CHHapticEngine?
    private var engineRunning = false
    private var observers: [NSObjectProtocol] = []

    init(intensity: Float = 1.0, sharpness: Float = 0.5, locality: String = "handles",
         onLog: ((String) -> Void)? = nil) {
        self.intensity = intensity
        self.sharpness = sharpness
        self.localityName = locality
        self.onLog = onLog
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            guard let self, let c = n.object as? GCController else { return }
            self.adopt(c)
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            guard let self, let c = n.object as? GCController, c === self.controller else { return }
            self.onLog?("haptics: \(c.vendorName ?? "controller") disconnected")
            self.dropEngine()
            self.controller = nil
            // The pad sleeps after ~15 min idle and comes back as a new
            // connection; if something else is already here, take it now.
            if let next = GCController.controllers().first(where: { $0.haptics != nil }) {
                self.adopt(next)
            }
        })
        // Controllers already paired when the daemon starts do not post a
        // connect notification; pick them up directly.
        for c in GCController.controllers() { adopt(c) }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// True once a controller with motors is in hand.
    var isReady: Bool { controller?.haptics != nil }

    /// One line for logs and `status`.
    var summary: String {
        "\(localityName), intensity \(intensity), sharpness \(sharpness)"
    }

    private func adopt(_ c: GCController) {
        guard controller == nil else { return }  // one pad is plenty
        guard c.haptics != nil else {
            onLog?("haptics: \(c.vendorName ?? "controller") has no haptics, ignored")
            return
        }
        controller = c
        dropEngine()
        onLog?("haptics: using \(c.vendorName ?? "?") (\(c.productCategory)) — \(summary)")
    }

    private func dropEngine() {
        engine = nil
        engineRunning = false
    }

    private func readyEngine() throws -> CHHapticEngine {
        if let e = engine {
            if !engineRunning { try e.start(); engineRunning = true }
            return e
        }
        let locality = Haptics.locality(named: localityName) ?? .handles
        guard let h = controller?.haptics, let e = h.createEngine(withLocality: locality) else {
            throw HapticsError.noController
        }
        // The engine can stop on its own (idle, interruption, pad asleep).
        // Forget it and rebuild on the next play rather than keep a dead one.
        e.resetHandler = { [weak self] in
            DispatchQueue.main.async { self?.dropEngine() }
        }
        e.stoppedHandler = { [weak self] reason in
            DispatchQueue.main.async {
                self?.onLog?("haptics: engine stopped (\(reason.rawValue))")
                self?.dropEngine()
            }
        }
        try e.start()
        engine = e
        engineRunning = true
        return e
    }

    /// Plays a pattern once. Failures are logged, never thrown: rumble is a
    /// courtesy, and nothing upstream should stall because the pad is asleep.
    func play(_ pattern: HapticPattern) {
        guard !pattern.isOff else { return }
        do {
            let e = try readyEngine()
            let events = pattern.pulses.map { p in
                CHHapticEvent(eventType: .hapticContinuous,
                              parameters: [
                                  CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                  CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                              ],
                              relativeTime: p.start,
                              duration: p.duration)
            }
            let player = try e.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            onLog?("haptics: play \(pattern.name) failed: \(error.localizedDescription)")
            dropEngine()
        }
    }
}

/// Polls Herdr for agent statuses and rumbles on the transitions a human
/// wants to know about: an agent becoming `blocked` (waiting on a prompt),
/// `done` (finished, not yet looked at), or going straight from `working`
/// to `idle` — which is what Herdr reports when the pane was on screen as
/// the agent finished, so no `done` ever shows up for it.
///
/// Polling rather than `events.subscribe`, on purpose: one `agent.list` every
/// half second on a local socket costs nothing, needs no per-pane
/// subscription bookkeeping, survives a Herdr restart, and sees new panes
/// without being told about them.
final class AgentWatcher {

    struct Settings {
        var enabled = false
        var pollMs = 500
        var blocked = HapticPattern.named("double")!
        var done = HapticPattern.named("single")!
        /// Skip the pane that has focus — you are already looking at it.
        var ignoreFocused = false
        var intensity: Float = 1.0
        var sharpness: Float = 0.5
        var locality = "handles"
    }

    var onLog: ((String) -> Void)?

    private let herdr: HerdrClient
    private let haptics: Haptics
    private let settings: Settings
    private let queue = DispatchQueue(label: "gamepad.agent-watcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Last seen status per pane id.
    private var last: [String: String] = [:]
    private var seeded = false
    private var lastPlay = Date.distantPast
    /// Floor between two rumbles, so a flapping status cannot buzz nonstop.
    private let minGap: TimeInterval = 1.0

    /// `herdr` should be this watcher's own client: requests run on a
    /// background queue, and the shared client is not built for two threads.
    init(herdr: HerdrClient, haptics: Haptics, settings: Settings) {
        self.herdr = herdr
        self.haptics = haptics
        self.settings = settings
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: .milliseconds(max(100, settings.pollMs)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        onLog?("haptics: watching agents every \(settings.pollMs) ms "
               + "(blocked=\(settings.blocked.name), done=\(settings.done.name))")
    }

    private func tick() {
        // Herdr down or restarting: skip this round, keep what we knew.
        guard let agents = try? herdr.agents() else { return }

        var now: [String: String] = [:]
        var chosen: HapticPattern? = nil
        var why: String? = nil
        for a in agents {
            now[a.paneID] = a.status
            guard seeded else { continue }
            // A pane we have not seen counts as coming from nothing, so a new
            // agent that is already waiting still gets a buzz.
            let before = last[a.paneID] ?? "idle"
            guard before != a.status else { continue }
            if settings.ignoreFocused, a.focused { continue }
            let pattern: HapticPattern
            switch a.status {
            case "blocked": pattern = settings.blocked
            case "done":    pattern = settings.done
            // Finished while its pane was on screen: Herdr says `idle`, not
            // `done`. Same news for the hand on the pad.
            case "idle" where before == "working": pattern = settings.done
            default:        continue
            }
            // Several transitions in one tick: the blocked one wins.
            if chosen == nil || a.status == "blocked" {
                chosen = pattern
                why = "\(a.paneID) \(a.title): \(before) → \(a.status)"
            }
        }
        last = now
        seeded = true

        guard let pattern = chosen, let reason = why else { return }
        let since = Date().timeIntervalSince(lastPlay)
        guard since >= minGap else {
            onLog?("haptics: skipped \(pattern.name) for \(reason) (\(Int(since * 1000)) ms after the last one)")
            return
        }
        lastPlay = Date()
        onLog?("haptics: \(pattern.name) for \(reason)")
        DispatchQueue.main.async { [haptics] in haptics.play(pattern) }
    }
}
