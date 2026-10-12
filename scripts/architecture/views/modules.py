"""Components group: the module overview (architecture grammar, flow top to bottom). overview_svg is moved verbatim from render.py."""
from collections import defaultdict
from draw import *
from . import Board, empty_svg

def overview_svg(doc, bidx, meta=None):
    meta = meta if meta is not None else {}
    mods = [x for x in doc["nodes"] if x["kind"] == "module"]
    ids = sorted(x["id"] for x in mods)
    by = {x["id"]: x for x in mods}
    hubs = ["mod:" + h for h in sorted(doc["overview_hidden"]["hubs"]) if "mod:" + h in by]
    vis = sorted((e["from"], e["to"]) for e in doc["edges"] if e["board"] == "overview" and "hidden" not in e)
    hub_users = sorted({e["from"] if e["to"] in hubs else e["to"] for e in doc["edges"]
                        if e["board"] == "overview" and e.get("hidden") == "hub" and (e["from"] in hubs or e["to"] in hubs)} - set(hubs))
    core = [i for i in ids if i not in hubs]
    succ = defaultdict(list)
    for a, b in vis:
        succ[a].append(b)
    # rank: longest path, back edges (cycles) ignored
    state, order, back = {}, [], set()
    def dfs(u):
        state[u] = 1
        for v in succ[u]:
            if state.get(v) == 1:
                back.add((u, v))
            elif v not in state:
                dfs(v)
        state[u] = 2
        order.append(u)
    for u in core:
        if u not in state:
            dfs(u)
    rank = {u: 0 for u in core}
    for u in reversed(order):
        for v in succ[u]:
            if (u, v) not in back:
                rank[v] = max(rank[v], rank[u] + 1)
    parents = defaultdict(list)
    for a, b in vis:
        if (a, b) not in back:
            parents[b].append(a)
    NS = 3
    NW = STEP_W
    PITCH = NW + GAP
    W = 2 * M + NS * NW + (NS - 1) * GAP
    sx0 = M
    slot, rows = {}, defaultdict(list)
    for u in core:
        rows[rank[u]].append(u)
    for r in sorted(rows):
        free = [0, 1, 2]
        todo = sorted(rows[r], key=lambda u: (min((slot[p] for p in parents[u]), default=9), u))
        for u in todo:
            pref = min((slot[p] for p in parents[u]), default=0)
            s = min(free, key=lambda f: (abs(f - pref), f))
            free.remove(s)
            slot[u] = s
    nrank = (max(rows) + 1) if rows else 0
    cx = lambda s: sx0 + s * PITCH + NW / 2
    # focal: the entry point, i.e. the rank-0 module with most outgoing arrows (1 max)
    r0 = sorted(rows[0], key=lambda u: (-len(succ[u]), u)) if rows else []
    focal = {r0[0]} if r0 and succ[r0[0]] else set()
    top_of = lambda u: by[u]["sources"][0]["path"].split("/")[0] if "/" in by[u]["sources"][0]["path"] else None
    cgroups = defaultdict(list)
    for u in ids:
        if top_of(u):
            cgroups[top_of(u)].append(u)
    cgroups = {k: v for k, v in cgroups.items() if len(v) > 1}
    def run_x(a, b):
        ra, rb = rank[a], rank[b]
        if rb == ra + 1:
            return cx(slot[a])
        for s in sorted(range(NS), key=lambda s: (s != slot[a], s != slot[b], s)):
            if all(s not in {slot[v] for v in rows[r]} for r in range(ra + 1, rb)):
                return cx(s)
        return sx0 - 8 if slot[a] < 1 else W - M + 8
    routes, chan = [], defaultdict(int)
    for a, b in vis:
        if (a, b) in back:
            continue
        ra, rb = rank[a], rank[b]
        rx = run_x(a, b)
        c1 = chan[ra]
        chan[ra] += 1
        c2 = None
        if rb > ra + 1:
            c2 = chan[rb - 1]
            chan[rb - 1] += 1
        routes.append((a, b, rx, c1, c2))
    first_row_of = {k: min(rank[u] for u in v) for k, v in sorted(cgroups.items()) if all(u in rank for u in v)}
    extra = defaultdict(int)  # zone header strip above a row
    for k, r in sorted(first_row_of.items()):
        if r > 0:
            extra[r - 1] = 32
    gaph = {r: max(48, 36 + 12 * chan[r]) + extra[r] for r in range(nrank)}
    ry, y = {}, M + 32
    for r in range(nrank):
        ry[r] = y
        y += NODE_H + (gaph[r] if r < nrank - 1 or hubs else 0)
    cv = Canvas(bidx)
    rect = {}
    for u in core:
        x = sx0 + slot[u] * PITCH
        rect[u] = (x, ry[rank[u]], NW, NODE_H)
        cv.node(u, x + NW / 2, ry[rank[u]] + NODE_H / 2, NW, NODE_H, by[u]["label"], by[u]["sources"][0]["path"], kind="focal" if u in focal else "step")
    if hubs:
        hy = y
        hw = (W - 2 * M - GAP * (len(hubs) - 1)) // len(hubs) // 4 * 4
        for k, hbn in enumerate(hubs):
            hx = sx0 + k * (hw + GAP)
            sub = f'{by[hbn]["sources"][0]["path"]} · used by {len(hub_users)}'
            cv.node(hbn, hx + hw / 2, hy + 40, hw, 80, by[hbn]["label"], sub, kind="store", tag="SHARED")
            rect[hbn] = (hx, hy, hw, 80)
            y = hy + 80
    gtop = lambda r: ry[r] + NODE_H + extra[r]
    for a, b, rx, c1, c2 in routes:
        ra, rb = rank[a], rank[b]
        ins = sorted((r_[0] for r_ in routes if r_[1] == b), key=lambda u: (cx(slot[u]), u))
        x2 = cx(slot[b]) + (ins.index(a) - (len(ins) - 1) / 2) * 24  # entry ports spread over the top side (12 px apart at least)
        # exit ports on the bottom side: a straight-down edge keeps the centre, the others leave 16 px to the side they head for
        x1 = x2 if x2 == cx(slot[a]) and rb == ra + 1 else cx(slot[a]) + 16 * ((x2 > cx(slot[a])) - (x2 < cx(slot[a])) or 1)
        ya = ry[ra] + NODE_H
        yb = ry[rb]
        ch1 = gtop(ra) + 20 + 12 * c1
        pts = [(x1, ya), (x1, ch1)]
        if rb == ra + 1:
            pts += [(x2, ch1), (x2, yb)]
        else:
            ch2 = gtop(rb - 1) + 20 + 12 * c2
            pts += [(rx, ch1), (rx, ch2), (x2, ch2), (x2, yb)]
        pts = [p for i, p in enumerate(pts) if i == 0 or p != pts[i - 1]]
        out = [pts[0]]
        for i in range(1, len(pts) - 1):
            p0, p1, p2 = out[-1], pts[i], pts[i + 1]
            if not ((p0[0] == p1[0] == p2[0]) or (p0[1] == p1[1] == p2[1])):
                out.append(p1)
        out.append(pts[-1])
        cv.edge(out, src=a, dst=b)
    meta["entry"] = sorted(focal)[0] if focal else (core[0] if core else "")
    for k, members in sorted(cgroups.items()):
        rs = [rect[u] for u in members if u in rect]
        if not rs:
            continue
        zx0, zy0 = min(r[0] for r in rs) - 16, min(r[1] for r in rs) - 32
        zx1, zy1 = max(r[0] + r[2] for r in rs) + 16, max(r[1] + r[3] for r in rs) + 16
        if any(not (r[0] + r[2] <= zx0 or r[0] >= zx1 or r[1] + r[3] <= zy0 or r[1] >= zy1) for u, r in sorted(rect.items()) if u not in members):
            continue
        lab = k.upper() + "/"
        lw = up4(tw(lab, SMALL, mono=True, track=0.18) + 16)
        lx = zx0 + 24 + lw / 2  # label sits on the top border at the left, clear of the entry arrows that cross it
        cv.back.append(f'<rect class="zone" x="{n(zx0)}" y="{n(zy0)}" width="{n(zx1 - zx0)}" height="{n(zy1 - zy0)}" rx="8" stroke-width="1" stroke-dasharray="{DASH}"/>'
                       f'<rect class="mask" x="{n(lx - lw / 2)}" y="{n(zy0 - 8)}" width="{n(lw)}" height="16" rx="2"/>'
                       f'<text class="eb" x="{n(lx + 1)}" y="{n(zy0 + 4)}" font-size="{SMALL}" text-anchor="middle">{esc(lab)}</text>')
    end = y + 16
    items = [("box", "Module"), ("line", "Calls into")] + ([("focal", "Entry point")] if focal else []) + ([("box", "Shared (arrows hidden)")] if hubs else [])
    lh = cv.legend(end, W, items, (meta or {}).get("note", ""))
    return cv.svg(W, up4(end + lh + M), "Modules", f"Architecture overview, {len(core) + len(hubs)} modules in {nrank} layers, flow top to bottom.")


def build(ctx):
    doc = ctx.doc
    ov = next(((i, b) for i, b in enumerate(doc["boards"]) if b["kind"] == "overview"), None)
    if ov is None or not any(x["kind"] == "module" for x in doc["nodes"]):
        return Board(id="overview", group="Components", title="Modules", purpose="Modules and how they call each other.", svg=empty_svg("No modules found"))
    h = doc["overview_hidden"]
    c = h["counts"]
    lab = {x["id"]: x["label"] for x in doc["nodes"] if x["kind"] == "module"}
    note = (f"Hidden to keep the board readable (all kept in the JSON): {c.get('hub', 0)} arrows to and from "
            f"{', '.join(lab['mod:' + x] for x in sorted(h['hubs'])) or 'no hub'}, {c.get('weaker-direction', 0)} weaker reverse arrows, "
            f"{c.get('implied', 0)} arrows already implied by a longer path.")
    meta = {"note": note}
    i, b = ov
    svg = overview_svg(doc, i, meta)
    nodes = [{"id": x["id"], "name": x["label"], "sub": x["sources"][0]["path"], "about": "", "anchor": "", "detail": "",
              "role": x.get("role", ""), "module": x.get("module"), "actor": x.get("actor"), "sources": x["sources"]}
             for x in doc["nodes"] if x["kind"] == "module"]
    return Board(id=b["id"], group="Components", title=b["title"], purpose=f"{len(lab)} modules; an arrow means one module calls into the other.",
                 svg=svg, nodes=nodes, notes=[note], entry=meta["entry"])
