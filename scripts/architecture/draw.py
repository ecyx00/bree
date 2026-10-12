"""Shared drawing kit for the architecture views: constants, geometry helpers and Canvas (a views/*.py module imports from here, never from render.py)."""
import html, json, os, re
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
M = 40                      # outer margin
NAME, SMALL = 13, 11        # node name (sans 600) / sub-label, arrow label, eyebrow, legend
DASH = "5,4"
NODE_H = 56
STEP_W = 184                # fixed step width and column pitch: x depends on rank only, never on label widths
LANE_LABEL_W = 140
GAP = 28                    # min gap between nodes (reference ramp)
EDGE_W = 1.2


def n(v):
    return f"{v:g}"


def esc(s):
    return html.escape(str(s), quote=True)


def up4(v):
    return int(-(-v // 4) * 4)


def tw(text, size, mono=False, bold=False, track=0.0):
    """Conservative text width estimate (check_svg.py in real Chrome is the actual test)."""
    return len(text) * (size * (0.62 if mono else (0.55 if bold else 0.52)) + track * size)


def short_label(text, limit=14):
    """Arrow labels are at most 14 characters, identifier case kept: keep whole words."""
    out = ""
    for w in text.split():
        t = (out + " " + w).strip()
        if len(t) > limit:
            break
        out = t
    return out or text[:limit]


def ortho(pts, r=8):
    d = [f"M{n(pts[0][0])},{n(pts[0][1])}"]
    for i in range(1, len(pts) - 1):
        (x0, y0), (x1, y1), (x2, y2) = pts[i - 1], pts[i], pts[i + 1]
        a = min(r, (abs(x1 - x0) + abs(y1 - y0)) / 2)
        b = min(r, (abs(x2 - x1) + abs(y2 - y1)) / 2)
        sx = (x1 > x0) - (x1 < x0)
        sy = (y1 > y0) - (y1 < y0)
        ex = (x2 > x1) - (x2 < x1)
        ey = (y2 > y1) - (y2 < y1)
        d.append(f"L{n(x1 - sx * a)},{n(y1 - sy * a)}Q{n(x1)},{n(y1)} {n(x1 + ex * b)},{n(y1 + ey * b)}")
    d.append(f"L{n(pts[-1][0])},{n(pts[-1][1])}")
    return "".join(d)


def overlap(a, b, pad=0):
    return a[0] < b[2] + pad and a[2] > b[0] - pad and a[1] < b[3] + pad and a[3] > b[1] - pad


class Canvas:
    """Collects drawing layers; svg() stacks them: back (lanes/zones), edges, labels, nodes, front (legend)."""

    def __init__(self, bid):
        self.bid, self.back, self.edges, self.labels, self.nodes, self.front = bid, [], [], [], [], []
        self.mk = f"ar{bid}"
        self.rects, self.segs, self.lrects = [], [], []  # placed node rects, edge segments, label rects (for label placement)

    def edge(self, pts, dashed=False, title=None, src=None, dst=None):
        self.edges.append(f'<path class="ed" data-from="{esc(src or "")}" data-to="{esc(dst or "")}" d="{ortho(pts)}" stroke-width="{EDGE_W}"' + (f' stroke-dasharray="{DASH}"' if dashed else "")
                          + f' marker-end="url(#{self.mk})">' + (f"<title>{esc(title)}</title>" if title else "") + "</path>")
        self.segs.append(pts)

    def label_rect(self, lines, rect):
        """Opaque mask plus one tracked mono text of 1..3 lines (plugin: 7.5 px mono, 0.12em, 12 px line pitch)."""
        x0, y0, x1, y1 = rect
        self.lrects.append(rect)
        cx = n((x0 + x1) / 2)
        spans = "".join(f'<tspan x="{cx}" dy="{0 if j == 0 else 12}">{esc(t)}</tspan>' for j, t in enumerate(lines))
        self.labels.append(f'<rect class="mask" x="{n(x0)}" y="{n(y0)}" width="{n(x1 - x0)}" height="{n(y1 - y0)}" rx="2"/>'
                           f'<text class="al" x="{cx}" y="{n(y0 + 12)}" font-size="{ELAB}" text-anchor="middle">{spans}</text>')

    def place_label(self, pts, lines, limit):
        """Mask rect beside the longest free segment with a 8 px gap to the stroke (never on it). Returns False if nothing fits."""
        if isinstance(lines, str):
            lines = [lines]
        w = up4(max(tw(t, ELAB, mono=True, track=0.08) for t in lines) + 8)
        h = 12 * len(lines) + 8
        segs = sorted(((abs(p[0] - q[0]) + abs(p[1] - q[1]), i) for i, (p, q) in enumerate(zip(pts, pts[1:]))), reverse=True)
        for ln, i in segs:
            p, q = pts[i], pts[i + 1]
            horiz = p[1] == q[1]
            if ln < (w + 16 if horiz else h + 16):
                continue
            for f in (0.5, 0.35, 0.65):
                for side in (0, 1):
                    if horiz:
                        cx = p[0] + (q[0] - p[0]) * f
                        y0 = p[1] - 8 - h if side == 0 else p[1] + 8
                        r = (cx - w / 2, y0, cx + w / 2, y0 + h)
                    else:
                        cy = p[1] + (q[1] - p[1]) * f
                        x0 = p[0] + 8 if side == 0 else p[0] - 8 - w
                        r = (x0, cy - h / 2, x0 + w, cy + h / 2)
                    if r[0] < 0 or r[1] < 0 or r[2] > limit[0] or r[3] > limit[1]:
                        continue
                    if any(overlap(r, nr, 2) for nr in self.rects) or any(overlap(r, lr, 4) for lr in self.lrects):
                        continue
                    if any(self.seg_hits(r, s, 6.5) for s in self.segs):
                        continue
                    self.label_rect(lines, tuple(round(v / 2) * 2 for v in r))
                    return True
        return False

    @staticmethod
    def seg_hits(r, pts, pad=2):
        for p, q in zip(pts, pts[1:]):
            sr = (min(p[0], q[0]) - 1, min(p[1], q[1]) - 1, max(p[0], q[0]) + 1, max(p[1], q[1]) + 1)
            if overlap(r, sr, pad):
                return True
        return False

    def node(self, nid, cx, cy, w, h, name, sub=None, kind="step", tag=None, diamond=False):
        """Centred node: opaque mask, styled box, name (sans 600) over one mono sub-label. kind: step | focal | store."""
        x, y = cx - w / 2, cy - h / 2
        self.rects.append((x, y, x + w, y + h))
        cls = "nb" + ("" if kind == "step" else " " + kind)
        g = [f'<g class="node" data-id="{esc(nid)}" tabindex="0" role="button" aria-label="{esc(name)}">']
        if diamond:
            pts = f"{n(cx)},{n(y)} {n(x + w)},{n(cy)} {n(cx)},{n(y + h)} {n(x)},{n(cy)}"
            g.append(f'<rect class="hit" x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}"/>'
                     f'<polygon class="mask" points="{pts}"/><polygon class="{cls}" points="{pts}" stroke-width="1"/>'
                     f'<text class="nm" x="{n(cx)}" y="{n(cy + 5)}" font-size="{NAME}" font-weight="600" text-anchor="middle">{esc(name)}</text>')
        else:
            g.append(f'<rect class="mask" x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}" rx="6"/>'
                     f'<rect class="{cls}" x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}" rx="6" stroke-width="{1.2 if kind == "focal" else 1}"/>')
            top = y + (24 if tag else 0)
            if tag:
                tww = up4(tw(tag, SMALL, mono=True, track=0.08) + 12)
                g.append(f'<rect class="tag" x="{n(x + 12)}" y="{n(y + 10)}" width="{n(tww)}" height="18" rx="2" stroke-width="0.8"/>'
                         f'<text class="tg" x="{n(x + 12 + tww / 2)}" y="{n(y + 23)}" font-size="{SMALL}" text-anchor="middle">{esc(tag)}</text>')
            g.append(f'<text class="nm" x="{n(cx)}" y="{n(top + 24)}" font-size="{NAME}" font-weight="600" text-anchor="middle">{esc(name)}</text>')
            if sub and sub.strip().lower() != name.strip().lower():  # a sub-label that repeats the name says nothing
                g.append(f'<text class="sb" x="{n(cx)}" y="{n(top + 42)}" font-size="{SMALL}" text-anchor="middle">{esc(sub)}</text>')
        g.append("</g>")
        self.nodes.append("".join(g))

    def flow_node(self, nid, cx, cy, w, h, name, sym, kind, diamond):
        """Compact step node (plugin look): opaque mask, warm fill, name in sans 600 (wrapped to 2 lines, never cut) over the symbol in mono.
        A decision is a diamond with the name only."""
        x, y = cx - w / 2, cy - h / 2
        self.rects.append((x, y, x + w, y + h))
        cls = "nb" + ("" if kind == "step" else " " + kind)
        g = [f'<g class="node" data-id="{esc(nid)}" tabindex="0" role="button" aria-label="{esc(name)}">']
        if diamond:
            pts = f"{n(cx)},{n(y)} {n(x + w)},{n(cy)} {n(cx)},{n(y + h)} {n(x)},{n(cy)}"
            lines = wrap_name(name, 104, max_lines=2) if tw(name, FNAME, bold=True) > 108 else [name]
            base = cy + 4 if len(lines) == 1 else cy - 3
            g.append(f'<rect class="hit" x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}"/>'
                     f'<polygon class="mask" points="{pts}"/><polygon class="{cls}" points="{pts}" stroke-width="1" stroke-linejoin="round"/>')
            for j, t in enumerate(lines):
                g.append(f'<text class="nm" x="{n(cx)}" y="{n(base + 15 * j)}" font-size="{FNAME}" font-weight="600" text-anchor="middle">{esc(t)}</text>')
        else:
            lines = wrap_name(name, w - 16)
            g.append(f'<rect class="mask" x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}" rx="6"/>'
                     f'<rect class="{cls}" x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}" rx="6" stroke-width="1"/>')
            base = y + (22 if len(lines) == 1 else 16)
            for j, t in enumerate(lines):
                g.append(f'<text class="nm" x="{n(cx)}" y="{n(base + 15 * j)}" font-size="{FNAME}" font-weight="600" text-anchor="middle">{esc(t)}</text>')
            g.append(f'<text class="sb" x="{n(cx)}" y="{n(y + (38 if len(lines) == 1 else 45))}" font-size="{FSUB}" text-anchor="middle">{esc(sym)}</text>')
        g.append("</g>")
        self.nodes.append("".join(g))

    def legend(self, y, width, items, note=""):
        """Bottom legend strip: hairline, LEGEND eyebrow, one row of keys (wraps). Returns the height used."""
        out = [f'<line class="l1" x1="{M}" y1="{n(y)}" x2="{n(width - M)}" y2="{n(y)}" stroke-width="0.8"/>',
               f'<text class="eb" data-sl="legend" x="{M}" y="{n(y + 24)}" font-size="{SMALL}">LEGEND</text>']
        x, row = M, 0
        for kind, text in items:
            gw = 20 if kind in ("box", "focal", "dia") else 32
            w = gw + 8 + tw(text, SMALL)
            if x + w > width - M and x > M:
                x, row = M, row + 1
            cy = y + 48 + row * 24
            if kind == "dia":
                out.append(f'<polygon class="dg" points="{n(x + 10)},{n(cy - 11)} {n(x + 20)},{n(cy - 4)} {n(x + 10)},{n(cy + 3)} {n(x)},{n(cy - 4)}" stroke-width="{EDGE_W}"/>')
            elif kind in ("box", "focal"):
                out.append(f'<rect class="nb{" focal" if kind == "focal" else ""}" x="{n(x + 3)}" y="{n(cy - 10)}" width="14" height="10" rx="2" stroke-width="1"/>')
            else:
                out.append(f'<line class="ed" x1="{n(x)}" y1="{n(cy - 4)}" x2="{n(x + 28)}" y2="{n(cy - 4)}" stroke-width="{EDGE_W}"'
                           + (f' stroke-dasharray="{DASH}"' if kind == "dash" else "") + f' marker-end="url(#{self.mk})"/>')
            out.append(f'<text class="lg" x="{n(x + gw + 8)}" y="{n(cy)}" font-size="{SMALL}">{esc(text)}</text>')
            x += w + 28
        extra = 0
        if note:  # the board note (what is hidden / where the flow starts) lives under the keys, wrapped to the board width
            ln, lines = "", []
            for w in note.split():
                if ln and tw(ln + " " + w, SMALL) > width - 2 * M:
                    lines.append(ln)
                    ln = w
                else:
                    ln = (ln + " " + w).strip()
            lines.append(ln)
            for k, t in enumerate(lines):
                out.append(f'<text class="lg" x="{M}" y="{n(y + 48 + (row + 1) * 24 + k * 18)}" font-size="{SMALL}">{esc(t)}</text>')
            extra = 18 * len(lines) + 6
        self.front.append("".join(out))
        return 24 + 24 * (row + 1) + 24 + extra

    def svg(self, width, height, title, desc):
        b = self.bid
        defs = (f'<defs><marker id="{self.mk}" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">'
                f'<polygon class="ar" points="0 0, 8 3, 0 6"/></marker></defs>')
        return (f'<svg viewBox="0 0 {n(width)} {n(height)}" width="{n(width)}" height="{n(height)}" role="img" aria-labelledby="t{b} d{b}">'
                f'<title id="t{b}">{esc(title)}</title><desc id="d{b}">{esc(desc)}</desc>{defs}' + "".join(self.back) + "".join(self.edges)
                + "".join(self.labels) + "".join(self.nodes) + "".join(self.front) + "</svg>")


# ---------------------------------------------------------------- flow boards (swimlane / process)
# Staircase layout after diagram-design's swimlane drawing: one column per rank (longest path from the entry), lanes are rows, the flow
# steps diagonally across lanes. A node centre is a pure function of (rank, lane, sub-row): no label width, no name length ever moves it.
FW, FH = 136, 52            # compact step node (plugin: 128x60)
FGAP = 40                   # gap between columns: room for two vertical runs 12 px apart plus 8 px of clearance each side
PITCH = FW + FGAP
DIA_W, DIA_H = FW, 76       # decision diamond, same column width
FNAME, FSUB, ELAB = 12, 10, 10   # node name (sans 600), node sub-label (mono), edge label (mono, tracked)
LANE_PAD = 30               # plugin: 30 px above and below a node inside its lane
ROW_GAP = 36                # vertical gap between two sub-rows of one lane
LEGEND_FLOW = [("box", "Step"), ("focal", "Entry / output"), ("line", "Call / next step"), ("dash", "Inferred")]


def group_of(actor):
    if actor in ("Claude Code agent", "User CLI"):
        return 0
    if actor in ("Index", "Files", "Git"):
        return 2
    return 1


def humanize(path):
    """A readable module name from a source path: the file stem ('hm/term.py' -> 'Term'); __init__ / index use the directory."""
    d, f = os.path.split(path.rstrip("/"))
    stem = os.path.splitext(f)[0]
    if stem in ("__init__", "index", "mod") and d:
        stem = os.path.basename(d)
    t = re.sub(r"[_\-.]+", " ", stem).strip() or f
    return t[:1].upper() + t[1:]


def name_of(s, names):
    """Short node name: the sidecar name when present, else the first three words of the label."""
    nm = names.get(s["anchor"])
    return nm or " ".join(s["label"].split()[:3])


def symbol_of(s):
    """Sub-label of a step node: the function it points at (anchor tail without the #fork / #line disambiguator)."""
    return s["anchor"].rsplit(":", 1)[-1].split("#")[0]


def wrap_name(text, limit, size=FNAME, max_lines=2):
    """Greedy word wrap of a node name; a name never loses a word (it grows a second line instead)."""
    lines, cur = [], ""
    for w in text.split():
        t = (cur + " " + w).strip()
        if cur and tw(t, size, bold=True) > limit:
            lines.append(cur)
            cur = w
        else:
            cur = t
    lines.append(cur)
    if len(lines) > max_lines:
        raise SystemExit(f"node name does not fit {max_lines} lines: {text!r}")
    return lines


def label_lines(text, limit=14):
    """Edge label: identifier case kept, words kept whole, wrapped at `limit` characters, never cut."""
    lines, cur = [], ""
    for w in text.split():
        t = (cur + " " + w).strip()
        if cur and len(t) > limit:
            lines.append(cur)
            cur = w
        else:
            cur = t
    return lines + [cur]


def seg_boxes(pts):
    return [((min(p[0], q[0]), min(p[1], q[1]), max(p[0], q[0]), max(p[1], q[1])), p[1] == q[1]) for p, q in zip(pts, pts[1:])]


def clean(pts):
    """Drop repeated points and middle points of straight runs."""
    out = []
    for p in pts:
        if not out or p != out[-1]:
            out.append(p)
    res = [out[0]]
    for i in range(1, len(out) - 1):
        a, b, c = res[-1], out[i], out[i + 1]
        if not ((a[0] == b[0] == c[0]) or (a[1] == b[1] == c[1])):
            res.append(b)
    res.append(out[-1])
    return res


def rank_of(steps, edges):
    """Longest path from the entry over forward edges (a back edge, order not increasing, never moves a node)."""
    rank = {s["id"]: 0 for s in steps}
    order = {s["id"]: s["order"] for s in steps}
    for s in steps:
        for e in edges:
            if e["to"] == s["id"] and order[e["from"]] < order[s["id"]]:
                rank[s["id"]] = max(rank[s["id"]], rank[e["from"]] + 1)
    return rank
