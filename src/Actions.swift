import Foundation

/// Executes what a binding asks for.
///
/// Two kinds of work land here:
///
///  * **Built-in actions** (`agent.next`, `agent.back`, …) need state or more
///    than one API call, so TOML alone cannot express them.
///  * **Raw methods** are forwarded untouched, which keeps all 85 socket
///    methods available without this file having to know about any of them.
final class ActionRunner {

    private let herdr: HerdrClient
    /// The user's own Herdr keybindings, so `key = "next_tab"` resolves to
    /// whatever they actually bound it to.
    private let keymap: Keymap
    /// Where focus was before the last jump, so `agent.back` can undo it.
    private var previousPaneID: String?

    init(herdr: HerdrClient, keymap: Keymap = .load()) {
        self.herdr = herdr
        self.keymap = keymap
    }

    /// Operations on Herdr that Herdr itself has no keybinding for.
    ///
    /// Anything Herdr can already do — next_tab, next_agent, focus_pane_left,
    /// zoom — is deliberately absent: those get sent as the user's own
    /// keybinding, so ordering matches the keyboard exactly. Only genuinely
    /// new behaviour earns a built-in here.
    ///
    /// Named in Herdr's snake_case style so one config reads consistently.
    static let herdrBuiltins = [
        "agent_next_waiting", "agent_previous_waiting",
        "agent_back", "agent_overview", "agent_read",
    ]

    /// Synthesised input-device behaviour. Not Herdr operations at all —
    /// these pretend to be a mouse.
    static let inputBuiltins = ["scroll_up", "scroll_down"]

    static var builtinNames: [String] { herdrBuiltins + inputBuiltins }

    /// Accessibility is requested lazily and only once — nagging on every
    /// stick movement would be unbearable.
    private var askedForScrollPermission = false

    /// Flips scroll direction. Which way feels "up" depends on the user's
    /// macOS natural-scrolling setting, so this cannot have a right default.
    var scrollInvert = false

    func run(action: String?, method: String?, key: String? = nil,
             sendKey: String? = nil, params: [String: Any]) {
        do {
            if let sendKey {
                try type(sendKey)
                return
            }
            if let key {
                try sendHerdrKey(key)
                return
            }
            let params = try resolve(params)
            if let action {
                try runBuiltin(action, params: params)
            } else if let method {
                try herdr.request(method, params)
            }
        } catch {
            // A daemon that dies on a bad binding is worse than one that
            // complains: surface it and keep listening.
            herdr.notify("Gamepad error", body: error.localizedDescription)
            FileHandle.standardError.write("gamepad: \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }

    // MARK: - Built-ins

    private func runBuiltin(_ action: String, params: [String: Any]) throws {
        switch action {
        case "agent_next_waiting":      try jump(offset: +1, waitingOnly: true)
        case "agent_previous_waiting":  try jump(offset: -1, waitingOnly: true)
        case "agent_back":              try goBack()
        case "agent_overview":          try overview()
        case "agent_read":              try readCurrent()
        // Negative wheel1 moves the view toward older output — the opposite of
        // what the sign name suggests. Verified against a real controller.
        case "scroll_up":               scroll(lines: -(params.int("lines") ?? 3))
        case "scroll_down":             scroll(lines: params.int("lines") ?? 3)
        default:
            throw HerdrClient.ClientError.api(
                code: "unknown_action",
                message: "`\(action)` is not a built-in. Use method = \"...\" for raw socket methods.")
        }
    }

    // MARK: - Literal keystrokes

    /// Types a key into whatever currently has focus.
    ///
    /// Unlike `sendHerdrKey`, this does not consult Herdr at all — it is for
    /// driving the program inside a pane: menus, fzf, pagers, TUIs.
    private func type(_ spec: String) throws {
        guard requireAccessibility() else { return }
        Keys.send(try Keys.parse(spec))
    }

    // MARK: - Herdr keybindings

    /// Presses whatever key the user has bound to a Herdr action.
    ///
    /// This is preferred over reimplementing the behaviour over the socket
    /// API: Herdr's own ordering logic runs, so the controller does exactly
    /// what the keyboard does.
    private func sendHerdrKey(_ name: String) throws {
        guard let spec = keymap.spec(for: name) else {
            throw ConfigError("`\(name)` is not a Herdr keybinding. "
                              + "Check the [keys] section of your config.toml.")
        }
        guard requireAccessibility() else { return }
        Keys.send(try Keys.parse(spec))
    }

    /// Synthesising input — keys or scroll wheel — needs Accessibility.
    ///
    /// Asked for once per run: prompting on every stick movement would be
    /// unbearable, and the prompt itself names the terminal that launched the
    /// daemon rather than this plugin, which is confusing enough to spell out.
    private func requireAccessibility() -> Bool {
        if Scroll.isPermitted { return true }
        if !askedForScrollPermission {
            askedForScrollPermission = true
            Scroll.requestPermission()
            herdr.notify("Gamepad needs Accessibility",
                         body: "System Settings → Privacy & Security → Accessibility, "
                               + "then allow the terminal that started the daemon, and restart it.")
        }
        return false
    }

    // MARK: - Scrolling

    private func scroll(lines: Int) {
        guard requireAccessibility() else { return }
        Scroll.post(lines: scrollInvert ? -lines : lines)
    }

    // MARK: - Parameter substitution

    /// Replaces `"$focused"` anywhere in a binding's params with the pane that
    /// currently has focus.
    ///
    /// Several methods (`pane.send_keys`, `pane.read`, …) require an explicit
    /// `pane_id`, which nobody can hardcode in a config file. This keeps every
    /// such method usable from TOML without inventing a built-in for each one.
    private func resolve(_ params: [String: Any]) throws -> [String: Any] {
        func needsSubstitution(_ value: Any) -> Bool {
            if let s = value as? String { return s == "$focused" }
            if let a = value as? [Any] { return a.contains(where: needsSubstitution) }
            return false
        }
        guard params.values.contains(where: needsSubstitution) else { return params }

        let current = try herdr.request("pane.current")
        guard let paneID = current["pane_id"] as? String else { return params }

        func substitute(_ value: Any) -> Any {
            if let s = value as? String { return s == "$focused" ? paneID : s }
            if let a = value as? [Any] { return a.map(substitute) }
            return value
        }
        return params.mapValues(substitute)
    }

    // MARK: - Workspace / tab cycling
    //
    // Herdr's socket API has `focus` (by id) and `list`, but no next/prev —
    // those exist only as keyboard bindings. So we list, find where we are,
    // and step. `number` is the field that gives a stable, human-visible order.

    private func cycleWorkspace(offset: Int) throws {
        let result = try herdr.request("workspace.list")
        let all = (result["workspaces"] as? [[String: Any]] ?? [])
            .sorted { ($0.int("number") ?? 0) < ($1.int("number") ?? 0) }
        guard all.count > 1 else {
            if all.isEmpty { herdr.notify("No workspaces") }
            return  // Nothing to cycle to; silence beats a pointless popup.
        }
        let current = all.firstIndex { $0.bool("focused") == true } ?? 0
        let target = all[(current + offset + all.count) % all.count]
        guard let id = target.string("workspace_id") else { return }
        try herdr.request("workspace.focus", ["workspace_id": id])
    }

    private func cycleTab(offset: Int) throws {
        let result = try herdr.request("tab.list")
        let everything = result["tabs"] as? [[String: Any]] ?? []
        // tab.list spans every workspace, so cycling without this filter would
        // silently teleport you out of the workspace you are working in.
        let currentWorkspace = everything
            .first { $0.bool("focused") == true }?
            .string("workspace_id")
        let all = everything
            .filter { $0.string("workspace_id") == currentWorkspace }
            .sorted { ($0.int("number") ?? 0) < ($1.int("number") ?? 0) }
        guard all.count > 1 else { return }

        let current = all.firstIndex { $0.bool("focused") == true } ?? 0
        let target = all[(current + offset + all.count) % all.count]
        guard let id = target.string("tab_id") else { return }
        try herdr.request("tab.focus", ["tab_id": id])
    }

    /// Herdr already returns agents in the order they appear in the UI, so we
    /// keep it.
    ///
    /// An earlier version sorted by `pane_id`, which was wrong: ids like
    /// `p19`, `p2P`, `p3M` are identifiers, not sequence numbers, so comparing
    /// them as strings produced an order with no relationship to what the user
    /// sees — "next agent" appeared to jump at random.
    private func sorted(_ agents: [HerdrClient.Agent]) -> [HerdrClient.Agent] {
        agents
    }

    private func jump(offset: Int, waitingOnly: Bool) throws {
        let all = sorted(try herdr.agents())
        let pool = waitingOnly ? all.filter(\.isWaiting) : all

        guard !pool.isEmpty else {
            herdr.notify(waitingOnly ? "No agents waiting" : "No agents",
                         body: waitingOnly ? "Nothing is blocked or done right now." : nil)
            return
        }

        // Continue from wherever focus currently is. When the focused pane is
        // not in the pool (common with waitingOnly), start at the beginning.
        let currentIndex = pool.firstIndex(where: \.focused)
        let target: HerdrClient.Agent
        if let currentIndex {
            target = pool[(currentIndex + offset + pool.count) % pool.count]
        } else {
            target = offset > 0 ? pool[0] : pool[pool.count - 1]
        }

        previousPaneID = all.first(where: \.focused)?.paneID
        try focus(target)
    }

    private func goBack() throws {
        guard let previousPaneID else {
            herdr.notify("No previous agent", body: "Jump to an agent first.")
            return
        }
        let all = try herdr.agents()
        let current = all.first(where: \.focused)?.paneID
        try herdr.request("pane.focus", ["pane_id": previousPaneID])
        self.previousPaneID = current
    }

    /// Deliberately silent.
    ///
    /// Moving focus IS the feedback — you can see where you landed. Announcing
    /// every hop also burned through Herdr's notification rate limit within
    /// seconds, which then starved the notifications that genuinely carry
    /// information (overview, read, errors).
    private func focus(_ agent: HerdrClient.Agent) throws {
        try herdr.request("pane.focus", ["pane_id": agent.paneID])
    }

    private func overview() throws {
        let all = sorted(try herdr.agents())
        guard !all.isEmpty else {
            herdr.notify("No agents", body: "Nothing is running under Herdr.")
            return
        }
        var counts: [String: Int] = [:]
        for a in all { counts[a.status, default: 0] += 1 }
        let summary = counts.sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: " · ")

        let waiting = all.filter(\.isWaiting)
        let detail = waiting.isEmpty
            ? "Nothing needs you."
            : "Waiting: " + waiting.prefix(5).map(\.title).joined(separator: ", ")
              + (waiting.count > 5 ? " (+\(waiting.count - 5))" : "")

        herdr.notify("\(all.count) agents · \(summary)", body: detail)
    }

    private func readCurrent() throws {
        let all = try herdr.agents()
        guard let current = all.first(where: \.focused) else {
            herdr.notify("No focused agent")
            return
        }
        let result = try herdr.request("pane.read", [
            "pane_id": current.paneID,
            "source": "recent",
            "lines": 6,
        ])
        // `pane.read` returns either a string or an array of lines depending
        // on the source; accept both rather than guessing.
        let text: String
        if let s = result["text"] as? String {
            text = s
        } else if let lines = result["lines"] as? [String] {
            text = lines.joined(separator: " ")
        } else {
            text = "(no output)"
        }
        let condensed = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " · ")

        herdr.notify("\(statusIcon(current.status)) \(current.title)",
                     body: String(condensed.prefix(240)))
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "working": return "●"
        case "done":    return "✓"
        case "blocked": return "!"
        case "idle":    return "○"
        default:        return "·"
        }
    }
}
