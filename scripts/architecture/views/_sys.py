"""Shared layout for the three system views (context, containers, deployment). Not a view: no build(), not in REGISTRY.

grid(): columns of fixed-pitch nodes, orthogonal edges through gutters and row gaps. A node centre depends on (column, row) only.
"""
import os
from draw import Canvas, M, NODE_H, STEP_W, GAP, EDGE_W, n, esc, up4, short_label
from . import Board, empty_svg

GUT = 96        # gutter between columns: 8 lanes 12 px apart
ROWGAP = 56     # gap between rows: room for a horizontal channel
ELEVEL = {"person": "Person", "external": "External", "process": "Process", "cli": "CLI", "hook": "Hook", "daemon": "Daemon", "store": "Store", "file": "File"}


def get(ctx):
    """The gated extraction, once per render (the three views share it); the first view that asks pays the tokens."""
    if getattr(ctx, "_system", None) is None:
        import extract_system
        root = ctx.root
        if not root:   # rendered without a repo root: nothing to read, and never an LLM call
            ctx._system = {"nodes": [], "edges": [], "stats": {}, "tokens": 0, "empty": True, "root": None}
            ctx._system["paid"] = 0
            return ctx._system
        ctx._system = extract_system.extract(root, budget=ctx.budget)
        ctx._system["root"] = root
        ctx._system["paid"] = ctx._system["tokens"]
    return ctx._system


def take_tokens(res):
    """Tokens are reported on the first board that asks, so the sum over boards equals the spend."""
    t, res["paid"] = res.get("paid", 0), 0
    return t


def notes(res, skipped=0):
    s = res["stats"]
    return [f"Extraction: nodes proposed {s['nodes_proposed']}, kept {s['nodes_kept']}, dropped {s['nodes_dropped']}; "
            f"edges proposed {s['edges_proposed']}, kept {s['edges_kept']}, inferred (dashed) {s['edges_inferred']}, dropped {s['edges_dropped']}."
            + (f" {skipped} kept edges not drawn (no free port or lane)." if skipped else "")]


def card_nodes(bid, nodes):
    out = []
    for x in nodes:
        path = x["cite"].rsplit(":", 1)[0]
        out.append({"id": f"{bid}:{x['id']}", "name": x["name"], "sub": x["sub"] or ELEVEL[x["kind"]], "about": x["about"],
                    "anchor": path + "#", "detail": f"{ELEVEL[x['kind']]}" + (f" on {x['host']}" if x["host"] else "") + f" - cited at {x['cite']}"})
    return out


def empty_board(bid, group, title, purpose, msg="No system description found"):
    return Board(id=bid, group=group, title=title, purpose=purpose, svg=empty_svg(msg))


def grid(cv, bid, cols, edges, focal=None, zones=None, edge_label=lambda e: e["label"]):
    """cols: [[node dict]] (node: id, name, sub, kind). edges: dicts with from, to, inferred (+ label fields). zones: [title] per column or None.
    Returns (W, bottom, edges not drawn)."""
    ncol, R = len(cols), max(len(c) for c in cols)
    top = M + (30 if zones else 0)
    colx = lambda c: M + (16 if zones else 0) + c * (STEP_W + GUT + (32 if zones else 0))   # node left edge
    cy = lambda r: top + r * (NODE_H + ROWGAP) + NODE_H / 2
    pos = {}
    for c, col in enumerate(cols):
        for r, x in enumerate(col):
            pos[x["id"]] = (c, r)
    W = colx(ncol - 1) + STEP_W + (16 if zones else 0) + M + 28   # + right gutter for loops
    bottom = cy(R - 1) + NODE_H / 2
    if zones:
        for c, col in enumerate(cols):
            x0 = colx(c) - 16
            cv.back.append(f'<rect class="zone" x="{n(x0)}" y="{n(M)}" width="{n(STEP_W + 32)}" height="{n(bottom + 20 - M)}" rx="8" stroke-width="1" stroke-dasharray="4,4"/>'
                           f'<text class="eb" x="{n(x0 + 14)}" y="{n(M + 20)}" font-size="11">{esc(zones[c].upper())}</text>')
    for c, col in enumerate(cols):
        for r, x in enumerate(col):
            cv.node(f"{bid}:{x['id']}", colx(c) + STEP_W / 2, cy(r), STEP_W, NODE_H, x["name"], x["sub"] or ELEVEL[x["kind"]],
                    kind="focal" if x["id"] == focal else ("store" if x["kind"] in ("store", "file") else "step"))
    gx = lambda g: colx(g) + STEP_W + (16 if zones else 0) + GUT / 2   # centre of gutter g (right of column g)
    E = [e for e in edges if e["from"] in pos and e["to"] in pos]
    # at most 4 edges per node side (ports 14 px apart inside a 56 px node); the surplus is not drawn and is counted in the notes
    side, kept = {}, []
    for e in sorted(E, key=lambda e: (e["inferred"], pos[e["from"]], pos[e["to"]], e["from"], e["to"])):
        (c1, _), (c2, _) = pos[e["from"]], pos[e["to"]]
        d = (c2 > c1) - (c2 < c1)
        e["_s"], e["_e"] = ("R" if d >= 0 else "L"), ("L" if d > 0 else "R")
        ks = ((e["from"], e["_s"]), (e["to"], e["_e"]))
        if any(side.get(k, 0) >= 4 for k in ks):
            continue
        for k in ks:
            side[k] = side.get(k, 0) + 1
        kept.append(e)
    skipped = len(E) - len(kept)
    E = kept
    slots = {}
    for e in E:   # ports on a side are ordered by the row of the node at the other end, so edges fan out without crossing at the node
        slots.setdefault((e["from"], e["_s"]), []).append((pos[e["to"]][1], e["to"], e))
        slots.setdefault((e["to"], e["_e"]), []).append((pos[e["from"]][1], e["from"], e))
    slot_of = {}
    for (nid, s_), lst in slots.items():
        for k, (_, _, e) in enumerate(sorted(lst, key=lambda t: t[:2])):
            slot_of[(id(e), nid, s_)] = k
    def port(e, nid, s_):
        c, r = pos[nid]
        m = side[(nid, s_)]
        return (colx(c) + (STEP_W if s_ == "R" else 0), cy(r) + (slot_of[(id(e), nid, s_)] - (m - 1) / 2) * 14)
    lane = {}
    for e in sorted(E, key=lambda e: (pos[e["from"]], pos[e["to"]], e["from"], e["to"])):
        (c1, r1), (c2, r2) = pos[e["from"]], pos[e["to"]]
        d = (c2 > c1) - (c2 < c1)
        (xa, ya), (xb, yb) = port(e, e["from"], e["_s"]), port(e, e["to"], e["_e"])
        def lx(g):
            k = lane.get(("g", g), 0)
            if k >= 8:
                raise LookupError
            lane[("g", g)] = k + 1
            return gx(g) + (k - 3.5) * 12
        try:
            if d == 0 or abs(c2 - c1) == 1:
                g = lx(c1) if d == 0 else lx(c1 if d > 0 else c2)
                pts = [(xa, ya), (g, ya), (g, yb), (xb, yb)]
            else:
                r = min(r1, r2) if r1 != r2 else r1
                k = lane.get(("r", r), 0)
                if k >= 3:
                    raise LookupError
                lane[("r", r)] = k + 1
                yc = cy(r) + NODE_H / 2 + 14 + k * 12
                g1, g2 = lx(c1 if d > 0 else c1 - 1), lx(c2 - 1 if d > 0 else c2)
                pts = [(xa, ya), (g1, ya), (g1, yc), (g2, yc), (g2, yb), (xb, yb)]
        except LookupError:   # no free lane left in a gutter or row gap: the edge is not drawn and is counted
            skipped += 1
            e["_pts"] = None
            continue
        cv.edge(pts, dashed=e["inferred"], title=("inferred: no verified cite" if e["inferred"] else None), src=f"{bid}:{e['from']}", dst=f"{bid}:{e['to']}")
        e["_pts"] = pts
    for e in E:
        lab = edge_label(e)
        if lab and e.get("_pts"):
            cv.place_label(e["_pts"], short_label(lab), (W, bottom + 40))
    return W, bottom + 40, skipped


def finish(cv, bid, title, desc, W, bottom, legend):
    lh = cv.legend(bottom + 8, W, legend)
    return cv.svg(W, up4(bottom + 8 + lh + M), title, desc)
