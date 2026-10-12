"""Flows group: one swimlane (or single-actor process) board per flow in the model. flow_svg is moved verbatim from render.py."""
from collections import defaultdict
from draw import *
from . import Board

def flow_svg(doc, board, bidx, nodes_by_board, names, meta=None):
    meta = meta if meta is not None else {}
    steps = sorted(nodes_by_board[board["id"]], key=lambda s: s["order"])
    sid = {s["id"]: s for s in steps}
    edges = sorted((e for e in doc["edges"] if e["board"] == board["id"] and e["from"] in sid and e["to"] in sid),
                   key=lambda e: (sid[e["from"]]["order"], sid[e["to"]]["order"]))
    tool = doc["repo"]
    groups = sorted({group_of(s.get("actor", "tool")) for s in steps})
    n_store = sum(group_of(s.get("actor", "tool")) == 2 for s in steps)
    if n_store < 2 and 0 not in groups:  # no caller lane and under 2 storage steps: lanes would carry no information
        groups = [1]
    nl = len(groups)
    lane_of = {s["id"]: (groups.index(group_of(s.get("actor", "tool"))) if nl > 1 else 0) for s in steps}
    dec = {s["id"]: bool(s.get("decision")) for s in steps}
    size = {i: ((DIA_W, DIA_H) if dec[i] else (FW, FH)) for i in sid}
    rank = rank_of(steps, edges)
    ncol = max(rank.values()) + 1
    # sub-row inside a lane when two steps share (rank, lane): by step order, so it never depends on text
    sub, seen = {}, defaultdict(int)
    for s in steps:
        k = (rank[s["id"]], lane_of[s["id"]])
        sub[s["id"]] = seen[k]
        seen[k] += 1
    # ---- phases (common region): before the fork / fork and branches / after the join, only with exactly one fork and a join
    phase = {s["id"]: 0 for s in steps}
    pnames = []
    fk = [s for s in steps if s.get("decision")]
    if len(steps) > 6 and len(fk) == 1:
        indeg = defaultdict(int)
        for e in edges:
            indeg[e["to"]] += 1
        join = next((s for s in steps if s["order"] > fk[0]["order"] and indeg[s["id"]] > 1), None)
        if join:
            for s in steps:
                phase[s["id"]] = 0 if s["order"] < fk[0]["order"] else (1 if s["order"] < join["order"] else 2)
            spans = [sorted({rank[i] for i in phase if phase[i] == k}) for k in range(3)]
            if all(spans) and spans[0][-1] < spans[1][0] and spans[1][-1] < spans[2][0]:
                pnames = ["BEFORE THE FORK", "FORK AND BRANCHES", "AFTER THE JOIN"]
    # ---- geometry
    lab_lines = {}
    if nl > 1:
        for k, gi in enumerate(groups):
            names_ = sorted({s.get("actor", "tool") for s in steps if group_of(s.get("actor", "tool")) == gi} - {"tool"})
            lines = [tool] if gi == 1 else names_
            wrapped = []
            for ln in lines:
                cur = ""
                for w in ln.split():
                    if cur and len(cur + " " + w) > 11:
                        wrapped.append(cur)
                        cur = w
                    else:
                        cur = (cur + " " + w).strip()
                wrapped.append(cur)
            lab_lines[k] = [x.upper() for x in wrapped]
        LW = 120
    else:
        LW = 0
    hmax = [max([size[i][1] for i in sid if lane_of[i] == k] + [FH]) for k in range(nl)]
    rows = [1 + max([sub[i] for i in sid if lane_of[i] == k] + [0]) for k in range(nl)]
    lane_h = [up4(hmax[k] + 2 * LANE_PAD + (rows[k] - 1) * (FH + ROW_GAP)) for k in range(nl)]
    PH = 28 if pnames else 0  # header strip for phase labels
    lane_top = [M + PH + sum(lane_h[:k]) for k in range(nl)]
    x0 = M + LW + 20
    lane_right = x0 + ncol * PITCH - FGAP + 20
    W = lane_right + M
    end = M + PH + sum(lane_h)
    cx_of = lambda i: x0 + rank[i] * PITCH + FW / 2
    cy_of = lambda i: lane_top[lane_of[i]] + LANE_PAD + hmax[lane_of[i]] / 2 + sub[i] * (FH + ROW_GAP)
    rect = lambda i: (cx_of(i) - size[i][0] / 2, cy_of(i) - size[i][1] / 2, cx_of(i) + size[i][0] / 2, cy_of(i) + size[i][1] / 2)
    cv = Canvas(bidx)
    for k, pn in enumerate(pnames):
        bx0 = x0 + spans[k][0] * PITCH - 10
        bx1 = x0 + spans[k][-1] * PITCH + FW + 10
        cv.back.append(f'<rect class="band" x="{n(bx0)}" y="{M}" width="{n(bx1 - bx0)}" height="{n(end - M)}" rx="6"/>'
                       f'<text class="eb" x="{n(bx0 + 10)}" y="{n(M + 18)}" font-size="{SMALL}">{esc(pn)}</text>')
    for s in steps:
        i = s["id"]
        cv.flow_node(i, cx_of(i), cy_of(i), size[i][0], size[i][1], name_of(s, names), symbol_of(s),
                     "focal" if s["order"] in (1, steps[-1]["order"]) else "step", dec[i])
    if nl > 1:
        for k in range(nl + 1):
            y = M + PH + sum(lane_h[:k])
            cv.back.append(f'<line class="{"l2" if k in (0, nl) else "l1"}" x1="{M}" y1="{n(y)}" x2="{n(lane_right)}" y2="{n(y)}" stroke-width="1"/>')
        cv.back.append(f'<line class="l2" x1="{n(M + LW)}" y1="{M + PH}" x2="{n(M + LW)}" y2="{n(end)}" stroke-width="1"/>')
        for k, lines in lab_lines.items():
            cyl = lane_top[k] + lane_h[k] / 2
            y0 = cyl - 8 * (len(lines) - 1) + 4
            for j, t in enumerate(lines):
                cv.back.append(f'<text class="eb" x="{M}" y="{n(y0 + 16 * j)}" font-size="{SMALL}">{esc(t)}</text>')
    # ---- edges: right port to left port, three-run orthogonal path with the vertical run in a column gap
    inc, out = defaultdict(list), defaultdict(list)
    for e in edges:
        inc[e["to"]].append(e)
        out[e["from"]].append(e)
    tport, sport = {}, {}
    for i, es in inc.items():
        es.sort(key=lambda e: (cy_of(e["from"]), sid[e["from"]]["order"]))
        for j, e in enumerate(es):  # fan the entries over the left side, 24 px apart (diamond: one vertex)
            tport[id(e)] = (rect(i)[0], cy_of(i) + (0 if dec[i] else (j - (len(es) - 1) / 2) * 24))
    for i, es in out.items():
        r = rect(i)
        if len(es) == 1:
            sport[id(es[0])] = ("r", (r[2], cy_of(i)))
            continue
        used = set()
        for e in sorted(es, key=lambda e: (abs(tport[id(e)][1] - cy_of(i)), sid[e["to"]]["order"])):
            dy = tport[id(e)][1] - cy_of(i)
            side = "r" if (dy == 0 or "r" not in used) else ("b" if dy > 0 else "t")
            if side in used:
                raise SystemExit(f"no free exit side on {i}")
            used.add(side)
            sport[id(e)] = (side, {"r": (r[2], cy_of(i)), "b": (cx_of(i), r[3]), "t": (cx_of(i), r[1])}[side])
    placed = []  # committed paths

    def ok(pts, a, b):
        for bx, hz in seg_boxes(pts):
            for j in sid:
                pad = -1 if j in (a, b) else 6
                if overlap(bx, rect(j), pad):
                    return False
            for q in placed:
                for qb, qh in seg_boxes(q):
                    if qh != hz:
                        continue
                    c, v = (1, 0) if hz else (0, 1)
                    if abs(bx[c] - qb[c]) < 12 and min(bx[v + 2], qb[v + 2]) - max(bx[v], qb[v]) > 8:
                        return False
        return True

    pend = []
    for e in edges:
        a, b = e["from"], e["to"]
        side, (sx, sy) = sport[id(e)]
        tx, ty = tport[id(e)]
        ca, cb = rank[a], rank[b]
        if cb <= ca:
            raise SystemExit(f"backward edge {a} -> {b}")
        if side == "r":
            cands = [[(sx, sy), (tx, ty)]] if sy == ty else []
            gaps = [ca] + ([cb - 1] if cb - 1 != ca else [])
            for g in gaps:
                for off in (20, 8, 32):
                    xv = x0 + g * PITCH + FW + off
                    cands.append([(sx, sy), (xv, sy), (xv, ty), (tx, ty)])
        else:
            cands = [[(sx, sy), (sx, ty), (tx, ty)]]
        pts = next((clean(c) for c in cands if ok(clean(c), a, b)), None)
        if pts is None:
            raise SystemExit(f"no route for edge {a} -> {b}")
        placed.append(pts)
        lab = e.get("label") or ("inferred" if e["via"] == "inferred" else None)
        cv.edge(pts, not e["solid"], title=e.get("label"), src=a, dst=b)
        if lab:
            pend.append((pts, label_lines(lab)))
    for pts, lines in pend:
        if not cv.place_label(pts, lines, (W, end)):
            raise SystemExit(f"edge label {lines} has no free spot (never truncated, so the layout must change)")
    meta["entry"] = steps[0]["id"]
    meta["lane"] = {i: (" / ".join(lab_lines[lane_of[i]]) if nl > 1 else tool) for i in sid}
    meta["sym"] = {i: symbol_of(sid[i]) for i in sid}
    fork = any(s.get("decision") for s in steps)
    lh = cv.legend(end + 32, W, LEGEND_FLOW + ([("dia", "Decision")] if fork else []), meta.get("note", ""))
    H = up4(end + 32 + lh + M)
    kind = "Swimlane" if nl > 1 else "Process"
    desc = (f"{kind} diagram, {len(steps)} steps" + (f" across {nl} lanes" if nl > 1 else "") + ": "
            + ", ".join(name_of(s, names) for s in steps) + ".")
    return cv.svg(W, H, board["title"] + " " + kind.lower(), desc)


def build(ctx):
    doc, names = ctx.doc, ctx.names
    steps_by = defaultdict(list)
    for x in doc["nodes"]:
        if x["kind"] == "step":
            steps_by[x["board"]].append(x)
    out = []
    for i, b in enumerate(doc["boards"]):
        if b["kind"] == "overview":
            continue
        meta = {"note": f"Entry: {b['entry']['symbol']} (chosen by {b['entry']['chosen_by']})."}
        svg = flow_svg(doc, b, i, steps_by, names, meta)
        st = sorted(steps_by[b["id"]], key=lambda s: s["order"])
        purpose = f"{st[0]['label']} \u2192 {st[-1]['label'][0].lower() + st[-1]['label'][1:]} ({len(st)} steps)."
        nodes = [{"id": s["id"], "name": name_of(s, names), "sub": meta["sym"][s["id"]], "about": ctx.about.get(s["anchor"], ""),
                  "anchor": s["anchor"].rsplit(":", 1)[0] + "#" + s["anchor"].rsplit(":", 1)[1].split("#")[0],
                  "detail": s["label"], "module": s.get("module"), "actor": s.get("actor"), "sources": s["sources"],
                  "lane": meta["lane"].get(s["id"], ""), "sym": meta["sym"][s["id"]]} for s in st]
        out.append(Board(id=b["id"], group="Flows", title=b["title"], purpose=purpose, svg=svg, nodes=nodes,
                         legend=LEGEND_FLOW, notes=[meta["note"]], entry=meta["entry"]))
    return out
