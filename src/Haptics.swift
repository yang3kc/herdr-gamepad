import Foundation
import GameController
import CoreHaptics

/// A named rumble, so the config can pick one per event by name.
enum HapticPattern: String, CaseIterable {
    case off, single, double, triple, long

    /// Pulses as (start offset, length, intensity 0…1), in seconds.
    var pulses: [(start: TimeInterval, duration: TimeInterval, intensity: Float)] {
        switch self {
        case .off:    return []
        case .single: return [(0.0, 0.18, 0.8)]
        case .double: return [(0.0, 0.25, 1.0), (0.40, 0.25, 1.0)]
        case .triple: return [(0.0, 0.15, 1.0), (0.30, 0.15, 1.0), (0.60, 0.15, 1.0)]
        case .long:   return [(0.0, 0.60, 1.0)]
        }
    }

    /// How long the whole pattern takes to play out.
    var totalDuration: TimeInterval {
        pulses.map { $0.start + $0.duration }.max() ?? 0
    }

    static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
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

    /// Which motors a pattern plays on. `handles` is both grip motors.
    var locality: GCHapticsLocality = .handles
    var onLog: ((String) -> Void)?

    private var controller: GCController?
    private var engine: CHHapticEngine?
    private var engineRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
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

    private func adopt(_ c: GCController) {
        guard controller == nil else { return }  // one pad is plenty
        guard c.haptics != nil else {
            onLog?("haptics: \(c.vendorName ?? "controller") has no haptics, ignored")
            return
        }
        controller = c
        dropEngine()
        onLog?("haptics: using \(c.vendorName ?? "?") (\(c.productCategory))")
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
        guard pattern != .off else { return }
        do {
            let e = try readyEngine()
            let events = pattern.pulses.map { p in
                CHHapticEvent(eventType: .hapticContinuous,
                              parameters: [
                                  CHHapticEventParameter(parameterID: .hapticIntensity, value: p.intensity),
                                  CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                              ],
                              relativeTime: p.start,
                              duration: p.duration)
            }
            let player = try e.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            onLog?("haptics: play \(pattern.rawValue) failed: \(error.localizedDescription)")
            dropEngine()
        }
    }
}

/// Polls Herdr for agent statuses and rumbles on the transitions a human
/// wants to know about: an agent becoming `blocked` (waiting on a prompt)
/// or `done` (finished, not yet looked at).
///
/// Polling rather than `events.subscribe`, on purpose: one `agent.list` every
/// half second on a local socket costs nothing, needs no per-pane
/// subscription bookkeeping, survives a Herdr restart, and sees new panes
/// without being told about them.
final class AgentWatcher {

    struct Settings {
        var enabled = false
        var pollMs = 500
        var blocked: HapticPattern = .double
        var done: HapticPattern = .single
        /// Skip the pane that has focus — you are already looking at it.
        var ignoreFocused = false
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
               + "(blocked=\(settings.blocked.rawValue), done=\(settings.done.rawValue))")
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
            onLog?("haptics: skipped \(pattern.rawValue) for \(reason) (\(Int(since * 1000)) ms after the last one)")
            return
        }
        lastPlay = Date()
        onLog?("haptics: \(pattern.rawValue) for \(reason)")
        DispatchQueue.main.async { [haptics] in haptics.play(pattern) }
    }
}
