# Xbox Series X|S as a desk-side supervisor for Claude Code agents

The layout one of us runs: a Bluetooth Xbox Series X|S controller driving
[Herdr](https://herdr.dev) with several Claude Code panes. The keyboard stays the
primary input. The pad is for the off hand: approve or deny, jump to the agent that
needs you, pick effort or model, dictate, compact or quit — without looking for the
right window.

**Verified on:** macOS 26.6.2 (Apple Silicon), Herdr 0.8.2, Xbox Wireless Controller
`045E:0B13` over Bluetooth, [superwhisper](https://superwhisper.com) for dictation,
Warp as the terminal. 2026-08-22.

These files are mirrored by hand from the author's dotfiles and may lag a layout pass
behind. Everything in them is annotated; the three lines you will want to change are
marked `ADJUST`.

## Requirements

What this setup assumes. Each one is a real dependency; the layout does not work
without the first six.

- **macOS**, Apple Silicon tested. The plugin reads the pad through IOKit HID and types
  through CGEvent; none of it runs on Linux or Windows.
- **Herdr**, verified on 0.8.2. The layout calls `agent.prompt`, `pane.send_text`,
  `pane.zoom`, `pane.focus_direction`, `pane.current` and `plugin.action.invoke` over
  the socket. The plugin manifest allows 0.7.0, but those calls were only checked on
  0.8.2 — run `herdr --version`.
- **Swift**, from the Xcode Command Line Tools (`xcode-select --install`), to build the
  plugin. No Xcode, no package manager, one binary.
- **This fork of herdr-gamepad** (`yang3kc/herdr-gamepad`). Upstream cannot see the
  D-pad, the triggers or Share on this pad, so a third of the layout does nothing there.
- **An Xbox Series X|S controller paired over Bluetooth** (USB VID:PID `045E:0B13`).
  The `[profile]` in `gamepad.toml` is measured for exactly that. An Xbox One pad, a
  wired pad, or a clone reports different usages and pages — run `gamepad.learn` /
  `gamepad.setup` and write your own profile; the bindings still apply.
- **Claude Code** running in the Herdr panes. Every slash command on the pad (`/`,
  `/effort`, `/model`, `/compact`, `/clear`, `/exit`) is Claude Code's. With Codex or
  another agent, retarget those bindings.
- **A dictation app with a global toggle hotkey**, for RT. superwhisper here; any app
  that toggles recording on a hotkey works. Optional — rebind RT if you have none.
- **Optional:** the `padkit` companion plugin in this folder, for the Xbox button; Warp
  as the terminal, or set `PADKIT_TERMINAL_APP` to yours.
- **macOS settings**, all covered in Install: Accessibility granted to the daemon binary
  (key bindings only), the Game Overlay switched off, and the pad left disabled in
  Karabiner-Elements if you run it.

## What is in this folder

| File | What it is |
|---|---|
| `gamepad.toml` | The controller profile (measured HID usages for this pad) and the layout |
| `herdr-keys.toml` | A keys-only copy of `~/.config/herdr/config.toml` — see "not obvious" below |
| `dev.herdr.gamepad.plist` | A LaunchAgent that runs the daemon; `__HOME__` and `__PLUGIN_ROOT__` are placeholders |
| `padkit/` | A two-file companion Herdr plugin: one shell action that brings the terminal to the front |

## The layout

```
        LB ──────────────┐              ┌────────────── RB
     prev agent          │              │           next agent
        LT  zoom pane                                RT  voice

        ┌──────────┐                        ┌────────┐
        │  D-PAD   │    ⧉ View   ≡ Menu     │   Y    │  next waiting agent
        │ ↑ /menu  │    model    effort     │ X    B │  Tab      Esc
        │ ←compact │        ⊕ Xbox          │   A    │  Return
        │ clear  → │    focus terminal      └────────┘
        │ ↓ quit   │     Share: shift+tab
        └──────────┘     (permission mode)
     ┌──────────┐                    ┌──────────┐
     │ L-STICK  │  ↑↓←→ arrow keys   │ R-STICK  │  ↑↓ scroll
     │  click:  │                    │  click:  │  ←→ focus pane
     │ overview │                    │  space   │
     └──────────┘                    └──────────┘
```

| Input | Does | Sent as |
|---|---|---|
| **A** / **B** / **X** | Return / Escape / Tab — approve, deny or interrupt, move between fields | key |
| **Y** | Jump to the next agent that is blocked or done (`agent_next_waiting`) | socket |
| **LB** / **RB** | Previous / next agent — sent as your own Herdr keybinding | key |
| **LT** | Toggle zoom on the focused pane (`pane.zoom`) | socket |
| **RT** | Toggle dictation — sends superwhisper's hotkey | key |
| **View ⧉** | `/model` — Claude Code's model picker, submitted with `agent.prompt` | socket |
| **Menu ≡** | `/effort` — Claude Code's effort picker, submitted with `agent.prompt` | socket |
| **Xbox ⊕** | Bring the terminal running Herdr to the front (`padkit`) | socket |
| **Share** | Shift+Tab — cycle Claude Code's permission mode | key |
| **D-pad ↑** | Type `/` into the focused pane — Claude Code's command menu opens; pick with the left stick and A | socket |
| **D-pad ←** / **→** / **↓** | Type `/compact` / `/clear` / `/exit` into the focused pane — **A runs it, B clears it** | socket |
| **L3** | Notification listing every agent's state (`agent_overview`) | socket |
| **R3** | Space — toggle an item in Claude Code's multi-select dialogs | key |
| **Left stick** | Arrow keys, auto-repeating — move the selection in a dialog or a picker | key |
| **Right stick** ↑↓ | Mouse wheel — scrolls Herdr's scrollback. Stick up scrolls the view down, like a trackpad | wheel |
| **Right stick** ←→ | Focus the pane to the left / right (`pane.focus_direction`) | socket |

"key" means a synthetic keystroke to whatever window is frontmost, which needs the
macOS Accessibility permission. "socket" means a call on Herdr's unix socket: no
permission, and it reaches the Herdr-focused pane whatever app is frontmost.

## Three rules that shaped it

1. **Nothing that changes or ends a session fires on one press.** The D-pad only
   *types* `/compact`, `/clear` and `/exit` into the input box (`pane.send_text`);
   you read it and press A. The two pickers are submitted, because opening a picker is
   harmless — and `agent.prompt` refuses when the agent is blocked on a dialog
   (`agent_blocked`) or when the pane's foreground process is not the agent
   (`agent_not_ready`), so a stray press types nothing.
2. **Socket over keystrokes wherever possible.** Everything on the D-pad, LT, View,
   Menu, Y, L3 and the Xbox button goes through the socket. Only Return / Escape / Tab,
   Shift+Tab, Space, the arrows, scrolling and the dictation hotkey are synthetic keys.
3. **Real buttons for the most-pressed actions**, stick clicks for the rare ones.
   Dictation started on a stick click and moved to RT for that reason.

Deliberately absent: Ctrl-C (a second one exits Claude Code; B interrupts, D-pad ↓ then
A quits) and workspace and tab switching (tried on the triggers, not needed).

## Rumble

`[haptics]` in `gamepad.toml` is the attention signal: two strong pulses on the grips when
any agent becomes `blocked` (a permission prompt or question is waiting), one short pulse
when one becomes `done` (finished, not yet looked at). The daemon polls `agent.list` every
500 ms and plays the pattern through GameController / CoreHaptics next to its IOKit
reader — no extra permission, the pad only has to be awake. Two buzzes are at least one
second apart. `ignore_focused = true` skips the pane you are already looking at. Every
buzz is one line in the daemon log; `bin/herdr-gamepad rumble double` plays one on demand.

## The profile

The built-in `xbox360` profile does not fit this pad, so `gamepad.toml` spells out the
measured HID usages. Over Bluetooth the pad spreads its inputs over four HID pages,
which is why the upstream plugin could not see a third of it:

| Input | HID page | Usage | Note |
|---|---|---|---|
| A B X Y | Button (0x09) | 1 2 4 5 | |
| LB RB | Button | 7 8 | |
| View, Menu, Xbox | Button | 11 12 13 | |
| L3 R3 | Button | 14 15 | |
| Share | **Consumer (0x0C)** | 0xB2 (178) | "Record" — mapped as `share` |
| Left stick | Generic Desktop | X / Y | 16-bit, 0…65535 |
| Right stick | Generic Desktop | Z / Rz | not triggers on this pad |
| LT / RT | **Simulation (0x02)** | Brake 0xC5 / Accelerator 0xC4 | 0…1023 |
| D-pad | Generic Desktop | **hat switch** 0x39 | 1 = up, 3 = right, 5 = down, 7 = left, 0 = centre — decoded by the fork, no entry needed |

Two quirks, both handled in the config: a stick pushed up reports the **low** end of
its range, so the stick direction names in `[input]` are swapped on purpose; and this
unit's left stick idles off-centre, hence `deadzone = 0.35`.

## Install

1. Install the fork (it is what reads the hat switch, the triggers and Share):
   `herdr plugin install yang3kc/herdr-gamepad`, or clone it and
   `herdr plugin link <clone>`.
2. Copy `gamepad.toml` and `herdr-keys.toml` into `$(herdr plugin config-dir gamepad)/`.
   Edit the three `ADJUST` lines in `gamepad.toml`: your Herdr next/previous-agent
   keys, your dictation hotkey, and the `padkit` action. Make `herdr-keys.toml` match
   your own `[keys]` block.
3. Optional — the Xbox button: `herdr plugin link <this folder>/padkit`. Set
   `PADKIT_TERMINAL_APP` in the plugin environment if your terminal is not Warp.
4. The LaunchAgent: replace `__HOME__` with your home directory and `__PLUGIN_ROOT__`
   with the plugin root shown by `herdr plugin list`, save it as
   `~/Library/LaunchAgents/dev.herdr.gamepad.plist`, then
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.herdr.gamepad.plist`.
5. Grant Accessibility to the binary itself: System Settings → Privacy & Security →
   Accessibility → `+` → ⇧⌘G → `<plugin root>/bin/herdr-gamepad`.
6. System Settings → Game Controllers: switch the Game Overlay **off**, or the Xbox
   button opens it and swallows keystrokes.
7. If you run Karabiner-Elements, leave the pad **disabled** in its Devices tab.
8. Check: `<plugin root>/bin/herdr-gamepad status` should list the controller and the
   bindings; `herdr plugin action invoke gamepad.learn` shows what each input sends.

## Three macOS things that are not obvious

**The daemon must be started by launchd, not from a terminal.** The plugin's `start.sh`
uses `nohup`, so the daemon inherits the terminal as its macOS *responsible process*.
macOS then evaluates the terminal's Accessibility entry and ignores the daemon's own, so
the permission can never be granted and the prompt returns on every restart. A
LaunchAgent-spawned process is responsible for itself, which is the whole point of the
plist in this folder.

**The Accessibility entry is tied to the binary's ad-hoc code signature.** Rebuilding or
reinstalling the plugin invalidates it. The give-away: the socket bindings (Y, L3, the
D-pad, LT, View, Menu, Xbox) keep working while every key binding goes silent. Re-add
the binary and it comes back.

**`herdr-keys.toml` exists because the plugin's TOML reader cannot parse multi-line
arrays.** If your `config.toml` has one, the plugin silently falls back to guessed
defaults for your keybindings. `HERDR_CONFIG_PATH` in the plist points it at the
stripped keys-only copy instead. Keep that copy in sync when you rebind anything.

## Operating it

```bash
launchctl kickstart -k gui/$(id -u)/dev.herdr.gamepad   # restart — the daemon reads gamepad.toml only at start
launchctl bootout   gui/$(id -u)/dev.herdr.gamepad      # stop the pad
herdr plugin action invoke gamepad.learn                # what does this button send? (2 min)
bin/herdr-gamepad rumble double                         # do the motors answer?
```

`GAMEPAD_DEBUG=1` in the plist's `EnvironmentVariables` logs every press to
`~/.local/state/herdr/plugins/gamepad/daemon.log`. The pad sleeps after about fifteen
minutes idle; the Xbox button wakes it.
