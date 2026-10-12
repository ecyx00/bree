"""Components group: the dependency graph (diagram-design dependency grammar). Ranked rows, a fan-in badge on every module, and import cycles
drawn as accent dashed back-edges that run around the outside of the stack. 0 LLM tokens.

Arrows into a hub (a module most others import) are not drawn: its badge counts them. Arrows implied by a longer path are not drawn either."""
import math
from collections import defaultdict

from draw import Canvas, M, NODE_H, STEP_W, SMALL, NAME, EDGE_W, DASH, up4, n, esc, tw, clean, ortho
from . import Board, empty_svg
from ._struct import units, layers, fan_in, find_cycles, split_back, node_dict, sub

BOARD_ID = "dependency"
NW, NH, NS, GX, OUT = STEP_W, 72, 4, 60, 64
LANES_IN = (-6, 6, -18, 18)


def _node(cv, nid, cx, cy, name, sub, badge, kind):
    x, y = cx - NW / 2, cy - NH / 2
    cv.rects.append((x, y, x + NW, y + NH))
    bw = up4(tw(badge, SMALL, mono=True, track=0.06) + 12)
    cv.nodes.append(
        f'<g class="node" data-id="{esc(nid)}" tabindex="0" role="button" aria-label="{esc(name)}">'
        f'<rect class="mask" x="{n(x)}" y="{n(y)}" width="{NW}" height="{NH}" rx="6"/>'
        f'<rect class="nb{"" if kind == "step" else " " + kind}" x="{n(x)}" y="{n(y)}" width="{NW}" height="{NH}" rx="6" stroke-width="1"/>'
        f'<rect class="tag" x="{n(x + NW - 12 - bw)}" y="{n(y + 8)}" width="{n(bw)}" height="18" rx="2" stroke-width="0.8"/>'
        f'<text class="tg" x="{n(x + NW - 12 - bw / 2)}" y="{n(y + 21)}" font-size="{SMALL}" text-anchor="middle">{esc(badge)}</text>'
        f'<text class="nm" x="{n(cx)}" y="{n(y + 46)}" font-size="{NAME}" font-weight="600" text-anchor="middle">{esc(name)}</text>'
        f'<text class="sb" x="{n(cx)}" y="{n(y + 63)}" font-size="{SMALL}" text-anchor="middle">{esc(sub)}</text></g>')


def _reduce(fwd):
    """Drop (a, b) when another forward path a -> ... -> b exists (transitive reduction of the DAG)."""
    succ = defaultdict(list)
    for a, b in fwd:
        succ[a].append(b)
    memo = {}

    def reach(x):
        if x not in memo:
            memo[x] = set()
            for y in succ[x]:
                memo[x] |= {y} | reach(y)
        return memo[x]
    return [(a, b) for a, b in fwd if not any(b in reach(c) for c in succ[a] if c != b)]


def build(ctx):
    u, e, cap_note = units(ctx)
    ids = sorted(u)
    if len(ids) < 2 or not e:
        return Board(id=BOARD_ID, group="Components", title="Dependency", purpose="Who depends on whom.", svg=empty_svg("No module dependencies found"))
    fwd, back = split_back(ids, e)
    L = layers(ids, e)
    fi = fan_in(set(ids), e)
    fo = defaultdict(int)
    for a, _ in set(e):
        fo[a] += 1
    cyc = find_cycles(ids, e)
    hub = {x for x in ids if fi[x] >= max(6, math.ceil(0.6 * (len(ids) - 1)))}
    shown = [(a, b) for a, b in _reduce(fwd) if b not in hub]
    hidden_hub = sum(1 for a, b in fwd if b in hub)
    # visual rows: a rank wider than NS columns wraps into several rows
    byrank = defaultdict(list)
    for x in ids:
        byrank[L[x]].append(x)
    parents = defaultdict(list)
    for a, b in shown:
        parents[b].append(a)
    slot, vrow, vrows = {}, {}, []
    for r in sorted(byrank):
        mem = sorted(byrank[r], key=lambda x: (sum(slot[p] for p in parents[x] if p in slot) / max(1, len([p for p in parents[x] if p in slot])) if any(p in slot for p in parents[x]) else (NS - 1) / 2, x))
        for c in range(0, len(mem), NS):
            chunk, free = mem[c:c + NS], list(range(NS))
            for x in chunk:
                ps = [slot[p] for p in parents[x] if p in slot]
                pref = sum(ps) / len(ps) if ps else (NS - 1) / 2
                s = min(free, key=lambda f: (abs(f - pref), f))
                free.remove(s)
                slot[x], vrow[x] = s, len(vrows)
            vrows.append(chunk)
    nr = len(vrows)
    xs0 = M + OUT
    cx = lambda x: xs0 + slot[x] * (NW + GX) + NW / 2
    W = xs0 + NS * NW + (NS - 1) * GX + OUT + M
    edges = [(a, b, False) for a, b in shown] + [(a, b, True) for a, b in back]
    edges.sort(key=lambda t: (vrow[t[0]], vrow[t[1]], cx(t[0]), cx(t[1]), t[0], t[1]))
    # gap channels: gap g sits below visual row g (g = -1: above row 0)
    cnt = defaultdict(int)
    chan = {}
    for a, b, bk in edges:
        ra, rb = vrow[a], vrow[b]
        g1 = ra
        chan[(a, b, 1)] = (g1, cnt[g1])
        cnt[g1] += 1
        if bk or rb > ra + 1:
            g2 = rb - 1
            chan[(a, b, 2)] = (g2, cnt[g2])
            cnt[g2] += 1
    gh = lambda g: max(48, 28 + 14 * cnt[g]) if cnt[g] else 48
    top_h = gh(-1) if cnt[-1] else 0
    ry, y = [], M + top_h
    for r in range(nr):
        ry.append(y)
        y += NH + (gh(r) if r < nr - 1 else 0)
    gap_top = lambda g: (M if g < 0 else ry[g] + NH)
    chy = lambda g, c: gap_top(g) + 20 + 14 * c
    # ports: spread over the node's bottom (out) / top (in) side, 12..14 px apart
    outs, ins = defaultdict(list), defaultdict(list)
    for a, b, bk in edges:
        outs[a].append((b, bk))
        ins[b].append((a, bk))

    def port(lst, node, other, bk):
        lst = sorted(lst, key=lambda t: (cx(t[0]), t[1], t[0]))
        i = lst.index((other, bk))
        pitch = min(14, 168 // max(1, len(lst) - 1)) if len(lst) > 1 else 0
        return cx(node) + (i - (len(lst) - 1) / 2) * pitch
    lanes = defaultdict(list)

    def gutter_x(g, k):
        if g == 0:
            return xs0 - 12 - 12 * k
        if g == NS:
            return xs0 + NS * NW + (NS - 1) * GX + 12 + 12 * k
        return xs0 + g * NW + (g - 1) * GX + GX / 2 + LANES_IN[k]

    def take(cands, y0, y1):
        for g in cands:
            for k in range(4 if g in (0, NS) else len(LANES_IN)):
                if all(y1 + 14 < s or y0 - 14 > t for s, t in lanes[(g, k)]):
                    lanes[(g, k)].append((y0, y1))
                    return gutter_x(g, k)
        return None
    cv = Canvas(BOARD_ID)
    cv.mk_b = cv.mk + "b"
    for x in ids:
        badge = f"{fi[x]} in"
        kind = " ".join((["store"] if fo[x] == 0 else []) + (["hubn"] if x in hub else [])) or "step"
        _node(cv, f"{BOARD_ID}:{x}", cx(x), ry[vrow[x]] + NH / 2, u[x]["label"], sub(u[x]), badge, kind)
    drawn_back = []
    for a, b, bk in edges:
        ra, rb = vrow[a], vrow[b]
        x1, x2 = port(outs[a], a, b, bk), port(ins[b], b, a, bk)
        ya, yb = ry[ra] + NH, ry[rb]
        g1, c1 = chan[(a, b, 1)]
        y1 = chy(g1, c1)
        if not bk and rb == ra + 1:
            pts = [(x1, ya), (x1, y1), (x2, y1), (x2, yb)]
        else:
            g2, c2 = chan[(a, b, 2)]
            y2 = chy(g2, c2)
            mid = (x1 + x2) / 2
            if bk:
                side = [0, NS] if mid < (xs0 * 2 + NS * NW + (NS - 1) * GX) / 2 else [NS, 0]
                rx = take(side, min(y1, y2), max(y1, y2))
            else:
                rx = take(sorted(range(NS + 1), key=lambda g: (abs((gutter_x(g, 0) if g in (0, NS) else xs0 + g * NW + (g - 1) * GX + GX / 2) - mid), g)), min(y1, y2), max(y1, y2))
            if rx is None:
                continue
            pts = [(x1, ya), (x1, y1), (rx, y1), (rx, y2), (x2, y2), (x2, yb)]
        pts = clean(pts)
        cls = "ed bk" if bk else "ed"
        cv.edges.append(f'<path class="{cls}" data-from="{esc(BOARD_ID + ":" + a)}" data-to="{esc(BOARD_ID + ":" + b)}" d="{ortho(pts)}" stroke-width="{EDGE_W}"'
                        + (f' stroke-dasharray="{DASH}" marker-end="url(#{cv.mk_b})"' if bk else f' marker-end="url(#{cv.mk})"') + "></path>")
        cv.segs.append(pts)
        if bk:
            drawn_back.append(pts)
    for pts in drawn_back:
        if cv.place_label(pts, "CYCLE", (W, y + 200)):
            cv.labels[-1] = cv.labels[-1].replace('class="al"', 'class="al cy"')
    end = y + 16
    nm = lambda x: u[x]["label"]
    note = " ".join(t for t in (
        cap_note,
        f"{hidden_hub} arrows into {', '.join(nm(h) for h in sorted(hub))} are not drawn; its badge counts them." if hidden_hub else "",
        "Cycle: " + "; ".join(" -> ".join(nm(x) for x in c) + " -> " + nm(c[0]) for c in cyc) + "." if cyc else "") if t)
    items = [("box", "Module"), ("line", "Depends on")] + ([("dash", "Import cycle (back-edge)")] if back else [])
    lh = cv.legend(end, W, items, note)
    svg = cv.svg(W, up4(end + lh + M), "Dependency", f"{len(ids)} modules in {nr} rows; a badge counts the modules that depend on each one.")
    if back:
        svg = svg.replace("</defs>", f'<marker id="{cv.mk_b}" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon class="arb" points="0 0, 8 3, 0 6"/></marker></defs>', 1)
    nodes = [node_dict(BOARD_ID, x, u[x], fi[x], fo[x]) for x in sorted(ids, key=lambda x: (vrow[x], slot[x]))]
    top = max(ids, key=lambda x: (fi[x], x))
    css = ("#b-dependency .nb.hubn{stroke-width:2}" + ("#b-dependency path.bk{stroke:var(--accent)}#b-dependency .arb{fill:var(--accent)}#b-dependency .al.cy{fill:var(--accent)}" if back else ""))
    return Board(id=BOARD_ID, group="Components", title="Dependency", purpose=f"{len(ids)} modules; a badge counts who depends on each one" + (f", {len(cyc)} import cycle." if cyc else "."),
                 svg=svg, nodes=nodes, legend=items, notes=[note] if note else [], css=css, entry=f"{BOARD_ID}:{top}")
