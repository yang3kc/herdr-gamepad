#!/usr/bin/env python3
"""Redraw the binding diagrams.

    python3 docs/gen.py && rsvg-convert -w 2000 docs/gamepad.svg -o docs/gamepad.png

Writes two files:

  docs/gamepad.svg   the annotated diagram used by the README and the site
  docs/pad.svg       the same shell with no callouts and an id per input,
                     inlined into docs/index.html so the web configurator can
                     light a control up when a real controller sends it
"""
import pathlib

HERE = pathlib.Path(__file__).resolve().parent

W, H = 1600, 910

BG      = "#0d1117"
BODY_ST = "#4b5666"
RECESS  = "#12171e"
CTRL_ST = "#586372"
TXT     = "#e6edf3"
DIM     = "#8b949e"
LEAD    = "#3d4756"
PREFIX  = "#d2a8ff"
INPUT   = "#ffa657"
CHIPBG  = "#1b2330"
CHIPST  = "#414d5e"

MONO = "ui-monospace, SFMono-Regular, Menlo, monospace"
SANS = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"

CHW = 9.9   # mono 16px advance width

out = []
def w(s): out.append(s)


# ── controller geometry (mirrored about x = 800) ───────────────────────
BODY = ("M 800,308 C 742,300 674,302 620,322 "
        "C 546,350 476,398 464,472 C 452,540 466,616 498,670 "
        "C 530,722 592,726 622,682 C 650,646 664,616 680,600 "
        "C 710,576 750,566 800,566 C 850,566 890,576 920,600 "
        "C 936,616 950,646 978,682 C 1008,726 1070,722 1102,670 "
        "C 1134,616 1148,540 1136,472 C 1124,398 1054,350 980,322 "
        "C 926,302 858,300 800,308 Z")

LSTICK = (662, 396)
RSTICK = (872, 500)
DPAD   = (742, 500)
FACE   = (972, 410)
FOFF   = 51
BACK   = (748, 382)
START  = (852, 382)
GUIDE  = (800, 348)


def stick(cx, cy):
    return f"""
  <circle cx="{cx}" cy="{cy}" r="44" fill="{RECESS}" stroke="#2b3340" stroke-width="2"/>
  <circle cx="{cx}" cy="{cy}" r="31" fill="url(#cap)" stroke="{CTRL_ST}" stroke-width="1.6"/>
  <circle cx="{cx}" cy="{cy}" r="18" fill="none" stroke="#232b36" stroke-width="1.4"/>"""


def dpad(cx, cy):
    a, b = 35, 12.5
    p = (f"M {cx-b},{cy-a} L {cx+b},{cy-a} L {cx+b},{cy-b} L {cx+a},{cy-b} "
         f"L {cx+a},{cy+b} L {cx+b},{cy+b} L {cx+b},{cy+a} L {cx-b},{cy+a} "
         f"L {cx-b},{cy+b} L {cx-a},{cy+b} L {cx-a},{cy-b} L {cx-b},{cy-b} Z")
    return f"""
  <circle cx="{cx}" cy="{cy}" r="42" fill="{RECESS}" stroke="#2b3340" stroke-width="2"/>
  <path d="{p}" fill="url(#ctrl)" stroke="{CTRL_ST}" stroke-width="1.6" stroke-linejoin="round"/>"""


FACE_COLORS = {"a": "#7ee787", "b": "#ff9492", "x": "#79c0ff", "y": "#e3b341"}

def facebtn(cx, cy, label):
    return f"""
  <circle cx="{cx}" cy="{cy}" r="25" fill="url(#ctrl)" stroke="{CTRL_ST}" stroke-width="1.6"/>
  <text x="{cx}" y="{cy+7}" class="glyph" fill="{FACE_COLORS[label]}">{label.upper()}</text>"""


# ── label blocks ───────────────────────────────────────────────────────
def chip(x, y, label, anchor):
    """Rounded key-cap. x is the left edge (anchor 'l') or right edge ('r')."""
    cw = max(44, len(label) * CHW + 20)
    lx = x if anchor == "l" else x - cw
    return (f'<rect x="{lx:.1f}" y="{y}" width="{cw:.1f}" height="29" rx="8" '
            f'fill="{CHIPBG}" stroke="{CHIPST}" stroke-width="1.4"/>'
            f'<text x="{lx+cw/2:.1f}" y="{y+20}" class="cap">{label}</text>'), cw


def diamond(x, y, size=5):
    return (f'<path d="M {x:.1f},{y-size} L {x+size:.1f},{y} L {x:.1f},{y+size} '
            f'L {x-size:.1f},{y} Z" fill="{PREFIX}"/>')


def block(x, y, cap, base, kind, pre, anchor):
    """One callout: key-cap, its base-layer action, and its prefix-layer action."""
    s, cw = chip(x, y, cap, anchor)
    fill = INPUT if kind == "input" else TXT
    if anchor == "l":
        tx = x + cw + 14
        s += f'<text x="{tx:.1f}" y="{y+20}" class="base" fill="{fill}">{base}</text>'
        if pre:
            s += diamond(tx + 6, y + 42)
            s += f'<text x="{tx+20:.1f}" y="{y+47}" class="pre">{pre}</text>'
    else:
        tx = x - cw - 14
        s += f'<text x="{tx:.1f}" y="{y+20}" class="base end" fill="{fill}">{base}</text>'
        if pre:
            s += f'<text x="{tx:.1f}" y="{y+47}" class="pre end">{pre}</text>'
            s += diamond(tx - len(pre) * 8.05 - 14, y + 42)
    return s


def leader(x1, y1, x2, y2):
    return (f'<path d="M {x1},{y1} L {x2},{y2}" stroke="{LEAD}" stroke-width="1.4" fill="none"/>'
            f'<circle cx="{x1}" cy="{y1}" r="3.6" fill="#1a212b" stroke="#6b7787" stroke-width="1.5"/>')


LX, RX = 1210, 390

left_blocks = [
    # y,   cap,       base action,             kind,    prefix action,     leader from
    (224, "LT",      "previous agent",        "herdr", "settings",       (634, 268)),
    (336, "LB",      "previous tab",          "herdr", "toggle sidebar", (622, 308)),
    (452, "L STICK", "scroll  ↑ ↓",           "input", None,             LSTICK),
    (556, "D-PAD",   "focus pane  ← ↑ ↓ →",   "herdr", None,             DPAD),
]

right_blocks = [
    (190, "RT",      "next agent",            "herdr", "help",           (966, 268)),
    (302, "RB",      "next tab",              "herdr", "new tab",        (978, 308)),
    (686, "R STICK", "arrow keys  ↑ ↓ ← →",   "input", None,             RSTICK),
]

face_rows = [
    ("Y", "goto — session picker", "herdr", "split horizontal"),
    ("B", "Space",                 "input", "split vertical"),
    ("A", "Return",                "input", "zoom"),
    ("X", "Escape",                "input", "last pane"),
]
FACE_Y, FACE_ROW = 420, 56


# ── document ───────────────────────────────────────────────────────────
w(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="{SANS}">')
w(f"""<defs>
  <linearGradient id="body" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#3d4653"/><stop offset=".55" stop-color="#2a323d"/>
    <stop offset="1" stop-color="#191f27"/>
  </linearGradient>
  <linearGradient id="ctrl" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#454f5d"/><stop offset="1" stop-color="#2b333e"/>
  </linearGradient>
  <linearGradient id="trig" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#3c4552"/><stop offset="1" stop-color="#252d38"/>
  </linearGradient>
  <radialGradient id="sheen" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#6d7b8e" stop-opacity=".45"/>
    <stop offset="1" stop-color="#6d7b8e" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="cap" cx="0.4" cy="0.3" r="0.85">
    <stop offset="0" stop-color="#4e5866"/><stop offset="1" stop-color="#262e39"/>
  </radialGradient>
  <filter id="shadow" x="-30%" y="-40%" width="160%" height="200%">
    <feGaussianBlur stdDeviation="24"/>
  </filter>
  <style>
    .cap   {{ font-family:{MONO}; font-size:16px; font-weight:700; fill:{TXT}; letter-spacing:.6px; text-anchor:middle; }}
    .base  {{ font-size:18.5px; }}
    .pre   {{ font-size:16.5px; fill:{PREFIX}; }}
    .end   {{ text-anchor:end; }}
    .h1    {{ font-family:{MONO}; font-size:30px; font-weight:700; fill:{TXT}; letter-spacing:.5px; }}
    .h2    {{ font-size:17px; fill:{DIM}; }}
    .glyph {{ font-family:{MONO}; font-size:20px; font-weight:700; text-anchor:middle; }}
    .lg    {{ font-size:16.5px; fill:{DIM}; }}
    .note  {{ font-family:{MONO}; font-size:14px; fill:#6e7b8b; }}
    .eng   {{ font-family:{MONO}; font-size:12px; fill:#7c8896; text-anchor:middle; letter-spacing:.4px; }}
  </style>
</defs>""")

w(f'<rect width="{W}" height="{H}" fill="{BG}"/>')

w('<text x="60" y="74" class="h1">herdr-gamepad</text>')
w('<text x="60" y="104" class="h2">every binding lives in config/gamepad.toml</text>')

# ── BACK / prefix card ─────────────────────────────────────────────────
w(f'<rect x="470" y="92" width="322" height="90" rx="14" fill="#1a1526" stroke="{PREFIX}" stroke-width="1.6"/>')
cs, cw = chip(494, 108, "BACK", "l")
w(cs)
w(f'<text x="{494+cw+14}" y="128" class="base" fill="{PREFIX}" font-weight="700">PREFIX</text>')
w('<text x="494" y="162" class="lg" fill="#c4b2dc">hold it, or tap it — then press any ◆</text>')
w(leader(*BACK, 760, 182))

w(block(830, 110, "START", "next workspace", "herdr", "previous workspace", "l"))
w(leader(*START, 814, 124))

# ── controller ─────────────────────────────────────────────────────────
w('<ellipse cx="800" cy="722" rx="320" ry="30" fill="#000000" opacity=".7" filter="url(#shadow)"/>')

# triggers and bumpers sit behind the shell, so the body clips them
# analog triggers, then bumpers — both tucked behind the shell
w(f'<rect x="634" y="244" width="92" height="48" rx="18" fill="url(#trig)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
w(f'<rect x="874" y="244" width="92" height="48" rx="18" fill="url(#trig)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
w(f'<rect x="620" y="290" width="120" height="46" rx="20" fill="url(#ctrl)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
w(f'<rect x="860" y="290" width="120" height="46" rx="20" fill="url(#ctrl)" stroke="{CTRL_ST}" stroke-width="1.6"/>')

w(f'<path d="{BODY}" fill="url(#body)" stroke="{BODY_ST}" stroke-width="2.2"/>')
w('<ellipse cx="800" cy="380" rx="300" ry="95" fill="url(#sheen)" opacity=".5"/>')
w('<path d="M 800,308 C 742,300 674,302 620,322" fill="none" stroke="#5f6c7e" stroke-width="2" opacity=".55"/>')
w('<path d="M 800,308 C 858,300 926,302 980,322" fill="none" stroke="#5f6c7e" stroke-width="2" opacity=".55"/>')

w(stick(*LSTICK))
w(dpad(*DPAD))
w(stick(*RSTICK))
for lbl, dx, dy in (("y", 0, -FOFF), ("b", FOFF, 0), ("a", 0, FOFF), ("x", -FOFF, 0)):
    w(facebtn(FACE[0] + dx, FACE[1] + dy, lbl))

w(f'<circle cx="{GUIDE[0]}" cy="{GUIDE[1]}" r="17" fill="{RECESS}" stroke="#333c4a" stroke-width="1.6"/>')
w(f'<circle cx="{GUIDE[0]}" cy="{GUIDE[1]}" r="8" fill="none" stroke="#2b3340" stroke-width="1.4"/>')
for cx, name in ((BACK[0], "back"), (START[0], "start")):
    w(f'<rect x="{cx-19}" y="{BACK[1]-11}" width="38" height="22" rx="11" fill="url(#ctrl)" stroke="{CTRL_ST}" stroke-width="1.4"/>')
    w(f'<text x="{cx}" y="{BACK[1]+28}" class="eng">{name}</text>')

# ── callouts ───────────────────────────────────────────────────────────
for y, cap, base, kind, pre, src in left_blocks:
    w(leader(src[0], src[1], RX + 16, y + 14))
    w(block(RX, y, cap, base, kind, pre, "r"))

for y, cap, base, kind, pre, src in right_blocks:
    w(leader(src[0], src[1], LX - 16, y + 14))
    w(block(LX, y, cap, base, kind, pre, "l"))

w(leader(1048, 410, LX - 16, FACE_Y + 14))
for i, (cap, base, kind, pre) in enumerate(face_rows):
    w(block(LX, FACE_Y + i * FACE_ROW, cap, base, kind, pre, "l"))

# ── legend ─────────────────────────────────────────────────────────────
ly = 796
w(f'<path d="M 60,{ly-32} L 1540,{ly-32}" stroke="#212831" stroke-width="1.4"/>')
w(diamond(68, ly - 5))
w(f'<text x="88" y="{ly}" class="lg"><tspan fill="{PREFIX}">prefix layer</tspan> — hold or tap BACK first. It really is Herdr’s prefix mode, so Herdr shows it.</text>')
w(f'<rect x="62" y="{ly+21}" width="12" height="12" rx="3" fill="{INPUT}"/>')
w(f'<text x="88" y="{ly+32}" class="lg"><tspan fill="{INPUT}">synthetic input</tspan> — real key and wheel events, sent to whatever has focus. Needs Accessibility.</text>')
w(f'<rect x="62" y="{ly+53}" width="12" height="12" rx="3" fill="{TXT}"/>')
w(f'<text x="88" y="{ly+64}" class="lg"><tspan fill="{TXT}">Herdr action</tspan> — sent as your own keybinding for it, so rebinding Herdr follows along.</text>')
w(f'<text x="1540" y="{ly}" class="note end">guide is eaten by the macOS Game Overlay — left unbound</text>')
w(f'<text x="1540" y="{ly+32}" class="note end">profile = xbox360 · also fits Xbox One and 8BitDo in X mode</text>')
w(f'<text x="1540" y="{ly+64}" class="note end">herdr plugin action invoke gamepad.learn — name any button</text>')

w("</svg>")

dest = HERE / "gamepad.svg"
dest.write_text("\n".join(out) + "\n")
print("wrote", dest)


# ═══════════════════════════════════════════════════════════════════════
#  docs/pad.svg — the same shell, stripped of callouts and tagged with
#  ids, so the web configurator can light a control up when the real
#  controller sends it.
# ═══════════════════════════════════════════════════════════════════════
pad = []
def q(s): pad.append(s)

q('<svg xmlns="http://www.w3.org/2000/svg" viewBox="436 214 728 528" class="pad">')
q(f"""<defs>
  <linearGradient id="pbody" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#3d4653"/><stop offset=".55" stop-color="#2a323d"/>
    <stop offset="1" stop-color="#191f27"/>
  </linearGradient>
  <linearGradient id="pctrl" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#454f5d"/><stop offset="1" stop-color="#2b333e"/>
  </linearGradient>
  <linearGradient id="ptrig" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#3c4552"/><stop offset="1" stop-color="#252d38"/>
  </linearGradient>
  <radialGradient id="psheen" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#6d7b8e" stop-opacity=".45"/>
    <stop offset="1" stop-color="#6d7b8e" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="pcap" cx="0.4" cy="0.3" r="0.85">
    <stop offset="0" stop-color="#4e5866"/><stop offset="1" stop-color="#262e39"/>
  </radialGradient>
</defs>""")

q(f'<g class="hw"><rect id="in-lt" x="634" y="244" width="92" height="48" rx="18" fill="url(#ptrig)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
q(f'<rect id="in-rt" x="874" y="244" width="92" height="48" rx="18" fill="url(#ptrig)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
q(f'<rect id="in-lb" x="620" y="290" width="120" height="46" rx="20" fill="url(#pctrl)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
q(f'<rect id="in-rb" x="860" y="290" width="120" height="46" rx="20" fill="url(#pctrl)" stroke="{CTRL_ST}" stroke-width="1.6"/></g>')

q(f'<path d="{BODY}" fill="url(#pbody)" stroke="{BODY_ST}" stroke-width="2.2"/>')
q('<ellipse cx="800" cy="380" rx="300" ry="95" fill="url(#psheen)" opacity=".5"/>')

for name, (cx, cy) in (("left", LSTICK), ("right", RSTICK)):
    q(f'<circle cx="{cx}" cy="{cy}" r="44" fill="{RECESS}" stroke="#2b3340" stroke-width="2"/>')
    q(f'<g id="stick-{name}"><circle id="in-{"l3" if name == "left" else "r3"}" cx="{cx}" cy="{cy}" r="31" '
      f'fill="url(#pcap)" stroke="{CTRL_ST}" stroke-width="1.6" class="hw"/>'
      f'<circle cx="{cx}" cy="{cy}" r="18" fill="none" stroke="#232b36" stroke-width="1.4"/></g>')

cx, cy = DPAD
a, b = 35, 12.5
q(f'<circle cx="{cx}" cy="{cy}" r="42" fill="{RECESS}" stroke="#2b3340" stroke-width="2"/>')
q(f'<path d="M {cx-b},{cy-a} L {cx+b},{cy-a} L {cx+b},{cy-b} L {cx+a},{cy-b} '
  f'L {cx+a},{cy+b} L {cx+b},{cy+b} L {cx+b},{cy+a} L {cx-b},{cy+a} '
  f'L {cx-b},{cy+b} L {cx-a},{cy+b} L {cx-a},{cy-b} L {cx-b},{cy-b} Z" '
  f'fill="url(#pctrl)" stroke="{CTRL_ST}" stroke-width="1.6" stroke-linejoin="round"/>')
for d, (x, y, ww, hh) in (("up",    (cx-b, cy-a, 2*b, a)),
                          ("down",  (cx-b, cy,   2*b, a)),
                          ("left",  (cx-a, cy-b, a,   2*b)),
                          ("right", (cx,   cy-b, a,   2*b))):
    q(f'<rect id="in-dpad_{d}" class="hw arm" x="{x}" y="{y}" width="{ww}" height="{hh}" rx="4" fill="transparent"/>')

for lbl, dx, dy in (("y", 0, -FOFF), ("b", FOFF, 0), ("a", 0, FOFF), ("x", -FOFF, 0)):
    bx, by = FACE[0] + dx, FACE[1] + dy
    q(f'<circle id="in-{lbl}" class="hw" cx="{bx}" cy="{by}" r="25" fill="url(#pctrl)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
    q(f'<text x="{bx}" y="{by+7}" class="glyph" fill="{FACE_COLORS[lbl]}" pointer-events="none">{lbl.upper()}</text>')

q(f'<circle id="in-guide" class="hw" cx="{GUIDE[0]}" cy="{GUIDE[1]}" r="17" fill="{RECESS}" stroke="#333c4a" stroke-width="1.6"/>')
q(f'<circle cx="{GUIDE[0]}" cy="{GUIDE[1]}" r="8" fill="none" stroke="#2b3340" stroke-width="1.4" pointer-events="none"/>')
for cx2, name in ((BACK[0], "back"), (START[0], "start")):
    q(f'<rect id="in-{name}" class="hw" x="{cx2-19}" y="{BACK[1]-11}" width="38" height="22" rx="11" '
      f'fill="url(#pctrl)" stroke="{CTRL_ST}" stroke-width="1.4"/>')
    q(f'<text x="{cx2}" y="{BACK[1]+28}" class="eng" pointer-events="none">{name}</text>')

q("</svg>")

padfile = HERE / "pad.svg"
padfile.write_text("\n".join(pad) + "\n")
print("wrote", padfile)


# ═══════════════════════════════════════════════════════════════════════
#  docs/og.svg — the 1200×630 social card. Same shell, same palette, sized
#  for the crop Twitter/Slack/Discord/iMessage all agree on (1.91:1).
# ═══════════════════════════════════════════════════════════════════════
OGW, OGH = 1200, 630
og = []
def o(s): og.append(s)

# place the pad's 436,214 728×528 frame into the right-hand half
SC = 600 / 728
TX, TY = 600 - 436 * SC, 104 - 214 * SC

o(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {OGW} {OGH}" '
  f'width="{OGW}" height="{OGH}" font-family="{SANS}">')
o(f"""<defs>
  <linearGradient id="body" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#3d4653"/><stop offset=".55" stop-color="#2a323d"/>
    <stop offset="1" stop-color="#191f27"/>
  </linearGradient>
  <linearGradient id="ctrl" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#454f5d"/><stop offset="1" stop-color="#2b333e"/>
  </linearGradient>
  <linearGradient id="trig" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#3c4552"/><stop offset="1" stop-color="#252d38"/>
  </linearGradient>
  <radialGradient id="sheen" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#6d7b8e" stop-opacity=".45"/>
    <stop offset="1" stop-color="#6d7b8e" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="cap" cx="0.4" cy="0.3" r="0.85">
    <stop offset="0" stop-color="#4e5866"/><stop offset="1" stop-color="#262e39"/>
  </radialGradient>
  <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="{PREFIX}" stop-opacity=".20"/>
    <stop offset="1" stop-color="{PREFIX}" stop-opacity="0"/>
  </radialGradient>
  <style>
    .ogbrow {{ font-family:{MONO}; font-size:17px; font-weight:700; fill:{PREFIX};
               letter-spacing:3.4px; }}
    .ogh1   {{ font-family:{MONO}; font-size:52px; font-weight:700; fill:{TXT};
               letter-spacing:.5px; }}
    .ogtag  {{ font-size:31px; font-weight:600; fill:{TXT}; }}
    .ogsub  {{ font-size:19px; fill:{DIM}; }}
    .ogurl  {{ font-family:{MONO}; font-size:17px; fill:#6e7b8b; }}
    .glyph  {{ font-family:{MONO}; font-size:20px; font-weight:700; text-anchor:middle; }}
    .eng    {{ font-family:{MONO}; font-size:12px; fill:#7c8896; text-anchor:middle;
               letter-spacing:.4px; }}
  </style>
</defs>""")

o(f'<rect width="{OGW}" height="{OGH}" fill="{BG}"/>')
o(f'<rect x="0" y="0" width="6" height="{OGH}" fill="{PREFIX}"/>')
o('<ellipse cx="880" cy="320" rx="420" ry="300" fill="url(#glow)"/>')

o(f'<g transform="translate({TX:.1f},{TY:.1f}) scale({SC:.4f})">')
o(f'<rect x="634" y="244" width="92" height="48" rx="18" fill="url(#trig)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
o(f'<rect x="874" y="244" width="92" height="48" rx="18" fill="url(#trig)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
o(f'<rect x="620" y="290" width="120" height="46" rx="20" fill="url(#ctrl)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
o(f'<rect x="860" y="290" width="120" height="46" rx="20" fill="url(#ctrl)" stroke="{CTRL_ST}" stroke-width="1.6"/>')
o(f'<path d="{BODY}" fill="url(#body)" stroke="{BODY_ST}" stroke-width="2.2"/>')
o('<ellipse cx="800" cy="380" rx="300" ry="95" fill="url(#sheen)" opacity=".5"/>')
o(stick(*LSTICK)); o(dpad(*DPAD)); o(stick(*RSTICK))
for lbl, dx, dy in (("y", 0, -FOFF), ("b", FOFF, 0), ("a", 0, FOFF), ("x", -FOFF, 0)):
    o(facebtn(FACE[0] + dx, FACE[1] + dy, lbl))
o(f'<circle cx="{GUIDE[0]}" cy="{GUIDE[1]}" r="17" fill="{RECESS}" stroke="#333c4a" stroke-width="1.6"/>')
o(f'<circle cx="{GUIDE[0]}" cy="{GUIDE[1]}" r="8" fill="none" stroke="#2b3340" stroke-width="1.4"/>')
for cx2, name in ((BACK[0], "back"), (START[0], "start")):
    o(f'<rect x="{cx2-19}" y="{BACK[1]-11}" width="38" height="22" rx="11" '
      f'fill="url(#ctrl)" stroke="{CTRL_ST}" stroke-width="1.4"/>')
    o(f'<text x="{cx2}" y="{BACK[1]+28}" class="eng">{name}</text>')
o('</g>')

o('<text x="76" y="150" class="ogbrow">HERDR PLUGIN</text>')
o('<text x="76" y="216" class="ogh1">herdr-gamepad</text>')
o('<text x="76" y="278" class="ogtag">Drive Herdr with</text>')
o('<text x="76" y="316" class="ogtag">a game controller.</text>')
o('<text x="76" y="366" class="ogsub">Patrol your AI agents, split panes and</text>')
o('<text x="76" y="392" class="ogsub">switch workspaces from the couch.</text>')

for i, (cap, what) in enumerate((("LT RT", "agents"), ("LB RB", "tabs"), ("BACK", "prefix"))):
    bx = 76 + i * 148
    cw = len(cap) * 9.9 + 20
    o(f'<rect x="{bx}" y="440" width="{cw:.0f}" height="28" rx="8" fill="{CHIPBG}" '
      f'stroke="{CHIPST}" stroke-width="1.4"/>')
    o(f'<text x="{bx + cw/2:.0f}" y="459" font-family="{MONO}" font-size="15" '
      f'font-weight="700" fill="{TXT}" text-anchor="middle">{cap}</text>')
    o(f'<text x="{bx + cw + 10:.0f}" y="460" class="ogsub">{what}</text>')

o('<text x="76" y="536" class="ogurl">htlin222.github.io/herdr-gamepad</text>')
o("</svg>")

ogfile = HERE / "og.svg"
ogfile.write_text("\n".join(og) + "\n")
print("wrote", ogfile)
