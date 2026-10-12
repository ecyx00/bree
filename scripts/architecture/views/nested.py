"""Components group: nested containment (diagram-design nested grammar). Repo > directory > module, each ring labelled on its top border.
Module names and roles come from the overview board; rings come from the module paths. 0 LLM tokens."""
import os
from collections import defaultdict

from draw import Canvas, M, GAP, NODE_H, STEP_W, SMALL, DASH, up4, n, esc, tw
from . import Board, empty_svg
from ._struct import units, fan_in, node_dict, sub

BOARD_ID = "nested"
HEAD, PADX, PADB, SP, LIMIT, MAXDEPTH = 36, 24, 24, 24, 3 * STEP_W + 2 * GAP + 2 * 24, 3


def _tree(u):
    """Directory tree of the units: {name, mods, kids}. A directory chain with one child and no module collapses into one ring."""
    root = {"name": "", "mods": [], "kids": {}}
    for k in sorted(u):
        d = u[k].get("dir", os.path.dirname(u[k]["path"]))
        node = root
        for part in [p for p in d.split("/") if p and p != "."][:MAXDEPTH]:
            node = node["kids"].setdefault(part, {"name": part, "mods": [], "kids": {}})
        node["mods"].append(k)

    def squash(t):
        t["kids"] = [squash(c) for _, c in sorted(t["kids"].items())]
        while len(t["kids"]) == 1 and not t["mods"] and t["name"]:
            c = t["kids"][0]
            t = {"name": t["name"] + "/" + c["name"], "mods": c["mods"], "kids": c["kids"]}
        return t
    return squash(root)


def _size(t, depth):
    """Shelf-pack the ring's items (modules, child rings) left to right; returns the ring's (w, h) and stores item offsets in t['items']."""
    items = [("m", k, STEP_W, NODE_H) for k in t["mods"]] + [("r", c, *_size(c, depth + 1)) for c in t["kids"]]
    pos, x, y, rowh, wmax = [], 0, 0, 0, 0
    for it in items:
        if x and x + it[2] > LIMIT - 2 * PADX:
            x, y, rowh = 0, y + rowh + SP, 0
        pos.append((it, x, y))
        x += it[2] + SP
        rowh = max(rowh, it[3])
        wmax = max(wmax, x - SP)
    t["items"] = pos
    t["w"] = max(wmax, 120) + 2 * PADX
    t["h"] = HEAD + (y + rowh if items else 0) + PADB
    return t["w"], t["h"]


def build(ctx):
    u, e, cap_note = units(ctx)
    if len(u) < 2:
        return Board(id=BOARD_ID, group="Components", title="Nested", purpose="Directories and modules by containment.", svg=empty_svg("No modules found"))
    root = _tree(u)
    root["name"] = ctx.doc.get("repo", "") or "repo"
    _size(root, 0)
    fi = fan_in(set(u), e)
    fo = defaultdict(int)
    for a, _ in set(e):
        fo[a] += 1
    focal = max(sorted(u), key=lambda x: fi[x]) if max(fi.values(), default=0) >= 2 else None
    cv = Canvas(BOARD_ID)
    W, H = int(root["w"]) + 2 * M, int(root["h"]) + 2 * M
    order = []

    def draw(t, x, y, depth):
        cv.back.append(f'<rect class="zone r{min(depth, 3)}" x="{n(x)}" y="{n(y)}" width="{n(t["w"])}" height="{n(t["h"])}" rx="8" stroke-width="1"/>')
        lab = t["name"].upper() + ("/" if depth else "")
        lw = up4(tw(lab, SMALL, mono=True, track=0.18) + 16)
        lx = x + 16 + lw / 2
        cv.back.append(f'<rect class="mask" x="{n(lx - lw / 2)}" y="{n(y - 8)}" width="{n(lw)}" height="16" rx="2"/>'
                       f'<text class="eb" x="{n(lx + 1)}" y="{n(y + 4)}" font-size="{SMALL}" text-anchor="middle">{esc(lab)}</text>')
        for it, ox, oy in t["items"]:
            ix, iy = x + PADX + ox, y + HEAD + oy
            if it[0] == "m":
                k = it[1]
                order.append(k)
                cv.node(f"{BOARD_ID}:{k}", ix + STEP_W / 2, iy + NODE_H / 2, STEP_W, NODE_H, u[k]["label"], sub(u[k]) if u[k].get("dir") is not None else os.path.basename(u[k]["path"]), kind="focal" if k == focal else "step")
            else:
                draw(it[1], ix, iy, depth + 1)

    draw(root, M, M, 0)
    ndirs = [0]

    def count(t):
        ndirs[0] += len(t["kids"])
        for c in t["kids"]:
            count(c)
    count(root)
    items = [("box", "Module"), ("focal", "Most depended on")] if focal else [("box", "Module")]
    lh = cv.legend(H - 8, W, items, " ".join(t for t in ("A ring is a directory; a module sits in the ring of the directory it lives in.", cap_note) if t))
    svg = cv.svg(W, up4(H - 8 + lh + M), "Nested", f"{len(u)} modules in {ndirs[0]} directories, by containment.")
    nodes = [node_dict(BOARD_ID, k, u[k], fi[k], fo[k]) for k in order]
    return Board(id=BOARD_ID, group="Components", title="Nested", purpose=f"{len(u)} modules inside {ndirs[0]} director{'ies' if ndirs[0] != 1 else 'y'}; outer rings contain inner ones.",
                 svg=svg, nodes=nodes, legend=items,
                 css="#b-nested .r0{fill:color-mix(in srgb,var(--ink) 2%,transparent);stroke:var(--rule)}"
                     "#b-nested .r1{fill:color-mix(in srgb,var(--ink) 3%,transparent);stroke:var(--rule-solid)}"
                     "#b-nested .r2,#b-nested .r3{fill:color-mix(in srgb,var(--ink) 4%,transparent);stroke:var(--soft)}",
                 entry=f"{BOARD_ID}:{focal}" if focal else "")
