"""Template for a new view. NOT in REGISTRY (the leading underscore marks it as a stub); copy it to views/<name>.py and edit.

Rules the shell and the gates enforce:
- build(ctx) returns a Board (or a list of Boards); ids are [a-z0-9-], unique across all views; node ids are unique across all boards.
- svg is drawn with draw.Canvas (nodes, orthogonal edges, masked labels, legend) so check_svg's rules hold; colours only through theme classes.
- A missing source gives views.empty_svg("No <thing> found"), never an exception and never a placeholder diagram.
- ctx.budget.charge(tokens, tag) for every LLM call (hard stop at the cap); a view with no LLM leaves Board.tokens = 0.
"""
from draw import Canvas, M, NODE_H, STEP_W, up4
from . import Board, empty_svg

BOARD_ID = "example"   # also the prefix of every node id


def build(ctx):
    mods = [x for x in ctx.doc["nodes"] if x["kind"] == "module"][:2]
    if len(mods) < 2:
        return Board(id=BOARD_ID, group="Context", title="Example", purpose="Stub view.", svg=empty_svg("No modules found"))
    cv = Canvas(BOARD_ID)                      # the id feeds the arrow marker id: keep it unique per board
    W, H = 2 * M + 2 * STEP_W + 72, 2 * M + 2 * NODE_H + 72
    cv.node(f"{BOARD_ID}:a", M + STEP_W / 2, M + NODE_H / 2, STEP_W, NODE_H, mods[0]["label"], mods[0]["sources"][0]["path"], kind="focal")
    cv.node(f"{BOARD_ID}:b", W - M - STEP_W / 2, H - M - NODE_H / 2, STEP_W, NODE_H, mods[1]["label"], mods[1]["sources"][0]["path"])
    ax, ay = M + STEP_W / 2, M + NODE_H
    bx, by = W - M - STEP_W / 2, H - M - NODE_H
    cv.edge([(ax, ay), (ax, H / 2), (bx, H / 2), (bx, by)], src=f"{BOARD_ID}:a", dst=f"{BOARD_ID}:b")
    lh = cv.legend(H - 8, W, [("box", "Module"), ("line", "Example edge")])
    svg = cv.svg(W, up4(H - 8 + lh + M), "Example", "Two modules and one edge.")
    nodes = [{"id": f"{BOARD_ID}:{k}", "name": m["label"], "sub": m["sources"][0]["path"], "about": "", "anchor": m["sources"][0]["path"] + "#"}
             for k, m in zip("ab", mods)]
    return Board(id=BOARD_ID, group="Context", title="Example", purpose="Stub view: two modules and one edge.", svg=svg, nodes=nodes,
                 legend=[("box", "Module"), ("line", "Example edge")], css="#b-example .nb{stroke-width:1}")
