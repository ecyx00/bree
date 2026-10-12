"""Containers group: deployment (dd type deployment): one dashed zone per place a part runs, arrows say what it reads or writes."""
from draw import Canvas
from . import Board
from . import _sys

BID = "deployment"
PURPOSE = "Where each part runs and what it reads or writes."
VERB = {"read": "reads", "write": "writes", "spawn": "starts", "call": "calls"}


def build(ctx):
    res = _sys.get(ctx)
    inner = [x for x in res["nodes"] if x["kind"] not in ("person", "external")][:9]
    if res["empty"] or not inner:
        return _sys.empty_board(BID, "Containers", "Deployment", PURPOSE, "No deployment information found")
    host = lambda x: x["host"] or ("on disk" if x["kind"] in ("store", "file") else "unspecified")
    zones = {}
    for x in inner:
        zones.setdefault(host(x), []).append(x)
    order = sorted(zones, key=lambda h: (-len(zones[h]), h))[:3]
    if len(zones) > 3:   # hosts beyond the third join the last zone, so no node is lost
        order[-1] = order[-1]
        for h in sorted(zones):
            if h not in order:
                zones[order[-1]] += zones[h]
    cols = [zones[h] for h in order]
    ids = {x["id"] for c in cols for x in c}
    edges = [dict(e) for e in res["edges"] if e["from"] in ids and e["to"] in ids][:8]
    inb = {}
    for e in edges:
        inb[e["to"]] = inb.get(e["to"], 0) + 1
    focal = max(inb, key=lambda k: (inb[k], k)) if inb else None
    cv = Canvas(BID)
    W, bottom, skipped = _sys.grid(cv, BID, cols, edges, focal=focal, zones=order, edge_label=lambda e: VERB[e["io"]])
    legend = [("box", "Part")] + ([("focal", "Most used (single point)")] if focal else []) + ([("line", "Reads / writes / starts")] if edges else []) \
        + ([("dash", "Inferred")] if any(e["inferred"] for e in edges) else [])
    svg = _sys.finish(cv, BID, "Deployment", "Where each part runs and what it reads or writes.", W, bottom, legend)
    return Board(id=BID, group="Containers", title="Deployment", purpose=PURPOSE, svg=svg, nodes=_sys.card_nodes(BID, [x for c in cols for x in c]),
                 legend=legend, notes=_sys.notes(res, skipped), tokens=_sys.take_tokens(res), entry=f"{BID}:{focal}" if focal else "")
