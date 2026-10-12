#!/usr/bin/env python3
"""Mirror of BreeChromePalette (CmuxFoundation/Color/BreeChromePalette.swift).

Prints every role's worst-surface contrast against its floor for real
Ghostty themes, in normal and Increase Contrast mode. Keep the math in step
with the Swift file: gamma-encoded sRGB mixing, 0.03928 luminance threshold, 2%
nudge steps toward white/black, floors checked against the four surfaces.

    python3 scripts/bree-palette-contrast.py          # table, exit 1 on a miss
    python3 scripts/bree-palette-contrast.py --swift  # print the test theme literals
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
THEMES = ["iTerm2 Solarized Light", "GitHub Light Default", "TokyoNight", "Dracula", "Gruvbox Dark"]
ACCENT = {"light": "#007AFF", "dark": "#0A84FF"}  # macOS blue accent, light / dark


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def lin(c): return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def mix(a, b, t): return tuple(min(1, max(0, x + (y - x) * t)) for x, y in zip(a, b))


def lum(c):
    f = lambda v: v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])


def contrast(a, b):
    x, y = lum(a), lum(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)


def darken(c, amount):  # amount may be negative (lighten)
    mx, mn = max(c), min(c)
    l = (mx + mn) / 2
    d = mx - mn
    h = s = 0
    if d:
        s = d / (1 - abs(2 * l - 1))
        if mx == c[0]: h = (c[1] - c[2]) / d + (6 if c[1] < c[2] else 0)
        elif mx == c[1]: h = (c[2] - c[0]) / d + 2
        else: h = (c[0] - c[1]) / d + 4
    nl = min(1, max(0, l - amount))
    ch = (1 - abs(2 * nl - 1)) * s
    x = ch * (1 - abs(h % 2 - 1))
    m = nl - ch / 2
    rgb = [(ch, x, 0), (x, ch, 0), (0, ch, x), (0, x, ch), (x, 0, ch), (ch, 0, x)][min(int(h), 5)]
    return tuple(v + m for v in rgb)


def selected_fill(c):
    scale = 1.0
    while scale > 0.2:
        if contrast((1, 1, 1), tuple(v * scale for v in c)) >= 6.2: break
        scale -= 0.01
    return tuple(v * scale for v in c)


def floor(role, ic):
    return {"textPrimary": 7, "textSecondary": 7 if ic else 4.5,
            "glyphTertiary": 4.5 if ic else 3, "borderStrong": 4.5 if ic else 3,
            "focusRing": 4.5 if ic else 3, "activeIndicator": 4.5 if ic else 3,
            "signalAttention": 4.5, "signalError": 4.5, "signalSuccess": 4.5, "signalInfo": 4.5,
            "selectedFill": 4.5}.get(role)


def palette(B, F, ansi, accent, ic):
    surf = [B, darken(B, 0.03), mix(B, F, 0.04), mix(B, F, 0.07)]
    worst = lambda c: min(contrast(c, s) for s in surf)

    def nudge(c, fl):
        if worst(c) >= fl: return c
        t = (1, 1, 1) if worst((1, 1, 1)) >= worst((0, 0, 0)) else (0, 0, 0)
        for i in range(1, 51):
            n = mix(c, t, i * 0.02)
            if worst(n) >= fl: return n
        return t

    def nudge_hue(c, fl):
        if worst(c) >= fl: return c
        d = -1 if worst((1, 1, 1)) >= worst((0, 0, 0)) else 1
        for i in range(1, 101):
            n = darken(c, d * i * 0.01)
            if worst(n) >= fl: return n
        return nudge(c, fl)

    def signal(i, role):
        fl = floor(role, ic)
        n, b = ansi[i], ansi[i + 8]
        chroma = lambda c: max(c) - min(c)
        a, b = nudge_hue(n, fl), nudge_hue(b, fl)
        return b if chroma(b) > chroma(a) else a

    r = {}
    r["borderStrong"] = nudge(mix(B, F, 0.35), floor("borderStrong", ic))
    r["textPrimary"] = nudge(F, 7)
    r["textSecondary"] = nudge(mix(B, F, 0.72), floor("textSecondary", ic))
    r["glyphTertiary"] = nudge(mix(B, F, 0.5), floor("glyphTertiary", ic))
    r["selectedFill"] = selected_fill(accent)
    r["focusRing"] = nudge(accent, floor("focusRing", ic))
    r["activeIndicator"] = nudge(accent, floor("activeIndicator", ic))
    for i, role in [(3, "signalAttention"), (1, "signalError"), (2, "signalSuccess"), (4, "signalInfo")]:
        r[role] = signal(i, role)
    return r, worst


def load(name):
    cfg = {"palette": {}}
    for line in open(os.path.join(ROOT, "Resources/ghostty/themes", name)):
        k, _, v = line.strip().partition(" = ")
        if k == "palette":
            i, _, h = v.partition("=")
            cfg["palette"][int(i)] = hexrgb(h)
        elif k in ("background", "foreground"):
            cfg[k] = hexrgb(v)
    return cfg["background"], cfg["foreground"], [cfg["palette"][i] for i in range(16)]


def hx(c): return "#%02X%02X%02X" % tuple(round(v * 255) for v in c)


def main():
    swift = "--swift" in sys.argv
    bad = 0
    for name in THEMES:
        B, F, ansi = load(name)
        scheme = "dark" if lum(B) < 0.179 else "light"
        accent = hexrgb(ACCENT[scheme])
        if swift:
            print(f'    Theme(name: "{name}", background: "{hx(B)}", foreground: "{hx(F)}",')
            print("          ansi: [" + ", ".join(f'"{hx(c)}"' for c in ansi) + "],")
            print(f'          accent: "{ACCENT[scheme]}"),')
            continue
        for ic in (False, True):
            r, worst = palette(B, F, ansi, accent, ic)
            print(f"\n{name} ({scheme}, accent {ACCENT[scheme]}, increase contrast {'on' if ic else 'off'})")
            print(f"  {'role':16} {'hex':8} {'worst':>6} {'floor':>5}  ok")
            for role, c in r.items():
                w = contrast(c, (1, 1, 1)) if role == "selectedFill" else worst(c)
                fl = floor(role, ic)
                ok = w >= fl - 1e-9
                if role.startswith("signal"): ok = ok and max(c) - min(c) >= 0.10
                bad += not ok
                print(f"  {role:16} {hx(c)} {w:6.2f} {fl:5}  {'yes' if ok else 'NO'}")
    if not swift:
        print("\nFAILURES:", bad)
        sys.exit(1 if bad else 0)


main()
