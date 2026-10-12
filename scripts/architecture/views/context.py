"""Context group: system context (C4 level 1, dd type architecture): people on top, the system in the middle, outside services below."""
from draw import Canvas, M, NODE_H, STEP_W, GAP, short_label
from . import Board
from . import _sys

BID = "context"
PURPOSE = "Who uses the system and which outside tools it talks to."


def build(ctx):
    res = _sys.get(ctx)
    outer = [x for x in res["nodes"] if x["kind"] in ("person", "external")][:8]
    inner = {x["id"] for x in res["nodes"]} - {x["id"] for x in outer} | {"system"}
    if res["empty"] or not outer:
        return _sys.empty_board(BID, "Context", "Context", PURPOSE, "No system context found" if res["empty"] else "No people or outside services found")
    people = [x for x in outer if x["kind"] == "person"][:4]
    ext = [x for x in outer if x["kind"] == "external"][:5]
    rows = [r for r in (people, ext) if r]
    cols = max(len(r) for r in rows)
    W = 2 * M + cols * STEP_W + (cols - 1) * GAP
    cv = Canvas(BID)
    gap = 104
    sys_cy = M + (NODE_H + gap if people else 0) + NODE_H / 2
    cy_of = {}
    for r, y in ((people, M + NODE_H / 2), (ext, sys_cy + NODE_H + gap)):
        for i, x in enumerate(r):
            cx = W / 2 + (i - (len(r) - 1) / 2) * (STEP_W + GAP)
            cy_of[x["id"]] = (cx, y)
            cv.node(f"{BID}:{x['id']}", cx, y, STEP_W, NODE_H, x["name"], x["sub"] or _sys.ELEVEL[x["kind"]],
                    kind="store" if x["kind"] == "external" else "step")
    name = ctx.doc.get("repo", "system")
    cv.node(f"{BID}:system", W / 2, sys_cy, W - 2 * M, NODE_H, name, "the system", kind="focal")
    # one arrow per outer node: collapse every kept edge that touches it onto the system box
    for x in people + ext:
        es = [e for e in res["edges"] if x["id"] in (e["from"], e["to"]) and ({e["from"], e["to"]} - {x["id"]}) & inner]
        if not es:
            continue
        e = es[0]
        cx, y = cy_of[x["id"]]
        inbound = e["from"] == x["id"]
        up = x["kind"] == "person"
        ya, yb = (y + NODE_H / 2, sys_cy - NODE_H / 2) if up else (y - NODE_H / 2, sys_cy + NODE_H / 2)
        pts = [(cx, ya), (cx, yb)] if inbound else [(cx, yb), (cx, ya)]   # the arrow points at the receiver; from = initiator
        a, b = (f"{BID}:{x['id']}", f"{BID}:system") if inbound else (f"{BID}:system", f"{BID}:{x['id']}")
        cv.edge(pts, dashed=all(k["inferred"] for k in es), title="inferred: no verified cite" if all(k["inferred"] for k in es) else None, src=a, dst=b)
        cv.place_label(pts, short_label(e["label"] or e["io"]), (W, sys_cy + NODE_H * 3 + gap * 2))
    bottom = cy_of[ext[0]["id"]][1] + NODE_H / 2 + 24 if ext else sys_cy + NODE_H / 2 + 24
    drawn = [x for x in res["edges"] if x["from"] in cy_of or x["to"] in cy_of]
    legend = [("box", " / ".join(t for t, on in (("Person", people), ("Outside system", ext)) if on))] + [("focal", "System")] \
        + ([("line", "Interaction")] if drawn else []) + ([("dash", "Inferred")] if any(x["inferred"] for x in drawn) else [])
    svg = _sys.finish(cv, BID, "System context", "People, the system and the outside services it uses.", W, bottom, legend)
    nodes = [{"id": f"{BID}:system", "name": name, "sub": "the system", "about": "", "anchor": "README.md#", "detail": "The repository as one box."}] + _sys.card_nodes(BID, people + ext)
    return Board(id=BID, group="Context", title="Context", purpose=PURPOSE, svg=svg, nodes=nodes, legend=legend, notes=_sys.notes(res, 0),
                 tokens=_sys.take_tokens(res), entry=f"{BID}:system")
