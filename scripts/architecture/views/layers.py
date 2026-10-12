"""Components group: the layer stack (diagram-design layers grammar). Modules in full-width bands by import rank, dependencies run downward.
Foundations (nothing below them) are the bottom band. Same module names as the overview board. 0 LLM tokens."""
from collections import defaultdict

from draw import Canvas, M, GAP, NODE_H, STEP_W, SMALL, EDGE_W, up4, n, esc
from . import Board, empty_svg
from ._struct import units, layers, fan_in, find_cycles, node_dict, sub

BOARD_ID = "layers"
LABEL_W, PAD, NCOL = 112, 16, 4


def build(ctx):
    u, e, cap_note = units(ctx)
    ids = sorted(u)
    if len(ids) < 2 or not e:
        return Board(id=BOARD_ID, group="Components", title="Layers", purpose="Modules stacked by import rank.", svg=empty_svg("No module imports found"))
    L = layers(ids, e)
    fi = fan_in(set(ids), e)
    fo = defaultdict(int)
    for a, _ in set(e):
        fo[a] += 1
    nb = max(L.values()) + 1
    rows = defaultdict(list)
    for x in ids:
        rows[L[x]].append(x)
    for r in rows:
        rows[r].sort(key=lambda x: (-fi[x], u[x]["label"], x))
    focal = max(ids, key=lambda x: (fi[x], x)) if max(fi.values()) >= 2 else None
    W = 2 * M + LABEL_W + 2 * PAD + NCOL * STEP_W + (NCOL - 1) * GAP
    x0 = M + LABEL_W + PAD
    cv = Canvas(BOARD_ID)
    y = M
    tops = []
    for r in range(nb):
        mem = rows.get(r, [])
        nr = max(1, -(-len(mem) // NCOL))
        h = 2 * PAD + nr * NODE_H + (nr - 1) * GAP
        tops.append((y, h))
        cv.back.append(f'<rect class="band" x="{M}" y="{n(y)}" width="{n(W - 2 * M)}" height="{n(h)}" rx="8"/>')
        lvl = nb - 1 - r
        cv.back.append(f'<text class="eb" x="{M + PAD}" y="{n(y + PAD + 12)}" font-size="{SMALL}">L{lvl}</text>'
                       f'<text class="sb" x="{M + PAD}" y="{n(y + PAD + 30)}" font-size="{SMALL}">{len(mem)} module{"s" if len(mem) != 1 else ""}</text>'
                       + (f'<text class="sb" x="{M + PAD}" y="{n(y + PAD + 48)}" font-size="{SMALL}">{"ENTRY" if r == 0 else "FOUNDATION" if r == nb - 1 else ""}</text>' if r in (0, nb - 1) else ""))
        for k, x in enumerate(mem):
            cx = x0 + (k % NCOL) * (STEP_W + GAP) + STEP_W / 2
            cy = y + PAD + (k // NCOL) * (NODE_H + GAP) + NODE_H / 2
            cv.node(f"{BOARD_ID}:{x}", cx, cy, STEP_W, NODE_H, u[x]["label"], sub(u[x]), kind="focal" if x == focal else "step")
        y += h + 8
    end = y - 8 + 16
    ax = M + LABEL_W - 4  # direction arrow: depends-on runs downward, outside the node area
    cv.front.append(f'<line class="ed" x1="{ax}" y1="{n(tops[0][0] + 12)}" x2="{ax}" y2="{n(end - 28)}" stroke-width="{EDGE_W}" marker-end="url(#{cv.mk})"/>')
    cyc = find_cycles(ids, e)
    note = " ".join(t for t in (cap_note, f"{len(cyc)} import cycle{'s' if len(cyc) != 1 else ''} ({' / '.join(u[c[0]]['label'] + ' ... ' + u[c[-1]]['label'] for c in cyc)}); the cycle's closing import is ignored for ranking." if cyc else "") if t)
    items = [("box", "Module")] + ([("focal", "Most depended on")] if focal else []) + [("line", "Higher layers depend on lower layers")]
    lh = cv.legend(end, W, items, note)
    svg = cv.svg(W, up4(end + lh + M), "Layers", f"{len(ids)} modules in {nb} layers by import rank; dependencies run downward.")
    nodes = [node_dict(BOARD_ID, x, u[x], fi[x], fo[x]) for r in range(nb) for x in rows.get(r, [])]
    return Board(id=BOARD_ID, group="Components", title="Layers", purpose=f"{len(ids)} modules in {nb} layers; each layer depends only on the layers below it.",
                 svg=svg, nodes=nodes, legend=items, notes=[note] if note else [], css="#b-layers .band{stroke:var(--rule);stroke-width:1}",
                 entry=f"{BOARD_ID}:{focal}" if focal else "")
