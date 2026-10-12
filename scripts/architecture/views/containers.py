"""Containers group: processes and stores (C4 level 2, dd type high-level): triggers on the left, running parts in the middle, data on the right."""
from draw import Canvas
from . import Board
from . import _sys

BID = "containers"
PURPOSE = "The processes, hooks, CLIs and data stores, and who calls whom."
COL = {"cli": 0, "hook": 0, "process": 1, "daemon": 1, "store": 2, "file": 2}


def build(ctx):
    res = _sys.get(ctx)
    inner = [x for x in res["nodes"] if x["kind"] in COL][:9]
    if res["empty"] or not inner:
        return _sys.empty_board(BID, "Containers", "Containers", PURPOSE, "No processes or stores found")
    cols = [[x for x in inner if COL[x["kind"]] == c] for c in range(3)]
    cols = [c for c in cols if c]
    ids = {x["id"] for x in inner}
    edges = [dict(e) for e in res["edges"] if e["from"] in ids and e["to"] in ids][:10]
    deg = {}
    for e in edges:
        for k in (e["from"], e["to"]):
            deg[k] = deg.get(k, 0) + 1
    focal = max(deg, key=lambda k: (deg[k], k)) if deg else None
    cv = Canvas(BID)
    W, bottom, skipped = _sys.grid(cv, BID, cols, edges, focal=focal)
    legend = [("box", "Process / CLI / hook")] + ([("focal", "Most connected")] if focal else []) + ([("line", "Call or data access")] if edges else []) \
        + ([("dash", "Inferred")] if any(e["inferred"] for e in edges) else [])
    svg = _sys.finish(cv, BID, "Containers", "Processes and stores of the system.", W, bottom, legend)
    return Board(id=BID, group="Containers", title="Containers", purpose=PURPOSE, svg=svg, nodes=_sys.card_nodes(BID, [x for c in cols for x in c]),
                 legend=legend, notes=_sys.notes(res, skipped), tokens=_sys.take_tokens(res), entry=f"{BID}:{focal}" if focal else "")
