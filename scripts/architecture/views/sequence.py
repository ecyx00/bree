"""Runtime group: one sequence board per flow. Lifelines are the modules of the steps, messages are the steps in walk order (0 tokens).
Grammar after diagram-design type-sequence: actor boxes on top, dashed lifelines, horizontal messages top to bottom, self-message as a U loop."""
import os
from draw import Canvas, M, DASH, esc, n, tw, up4, wrap_name, name_of, symbol_of, group_of
from . import Board, empty_svg
from ._runtime import flows, fit, slug, anchor_link, STORE_TAG

PITCH_X, AW, AH, ROW = 232, 168, 64, 60
LOOP_W, LOOP_H = 28, 24
LABEL_W = 184  # fits 26 characters of 11px bold


def _label(cv, nid, name, x, y, anchor="middle"):
    """Message label as a clickable node: opaque pill with the step name (same text as on the swimlane board)."""
    w = LABEL_W  # fixed: a pill never moves or resizes with the name
    x0 = x - w / 2 if anchor == "middle" else x
    cv.rects.append((x0, y - 22, x0 + w, y - 4))
    cv.nodes.append(f'<g class="node" data-id="{esc(nid)}" tabindex="0" role="button" aria-label="{esc(name)}">'
                    f'<rect class="mask" x="{n(x0)}" y="{n(y - 22)}" width="{n(w)}" height="18" rx="3"/>'
                    f'<text class="nm" x="{n(x0 + w / 2)}" y="{n(y - 9)}" font-size="11" font-weight="600" text-anchor="middle">{esc(name)}</text></g>')
    return x0, w


def board_for(ctx, b, steps, edges):
    names, doc = ctx.names, ctx.doc
    mods = {x["id"]: x for x in doc["nodes"] if x["kind"] == "module"}
    # lifelines: the caller (when the entry step has one), the modules in order of first call, then the stores (db / fs / git) the steps touch
    def part(s):  # the lifeline a step's message ARRIVES at
        return ("store:" + s["actor"]) if group_of(s.get("actor", "tool")) == 2 and s["actor"] in STORE_TAG else s["module"]
    caller = steps[0]["actor"] if group_of(steps[0].get("actor", "tool")) == 0 else None
    order = (["caller:" + caller] if caller else []) + list(dict.fromkeys(s["module"] for s in steps)) + list(dict.fromkeys(part(s) for s in steps if part(s).startswith("store:")))
    box = {m: ({"label": m[7:], "sources": [{"path": "caller"}]} if m.startswith("caller:") else
               {"label": {"Index": "Index db", "Files": "Files", "Git": "Git"}[m[6:]], "sources": [{"path": STORE_TAG[m[6:]].lower() + " store"}]} if m.startswith("store:") else
               mods.get(m, {"label": m, "sources": [{"path": m}]})) for m in order}
    lx = {m: M + AW / 2 + k * PITCH_X for k, m in enumerate(order)}
    sid = {s["id"]: s for s in steps}
    inc = {}
    for e in sorted(edges, key=lambda e: sid[e["from"]]["order"]):
        inc.setdefault(e["to"], e)
    bid = "seq-" + slug(b["id"])
    cv = Canvas(bid)
    W = up4(lx[order[-1]] + AW / 2 + LOOP_W + 240 + M)
    top = M + AH + 44
    nodes, msgs = [], []
    for i, s in enumerate(steps):
        y = top + i * ROW
        e = inc.get(s["id"])
        src = sid[e["from"]]["module"] if e else (order[0] if caller else s["module"])
        dst = part(s)
        nid = bid + ":" + s["id"].split(":", 1)[1]
        name = name_of(s, names)
        dashed = bool(e) and not e.get("solid", True)
        if src == dst:
            x = lx[dst]
            cv.edge([(x, y), (x + LOOP_W, y), (x + LOOP_W, y + LOOP_H), (x, y + LOOP_H)], dashed, src=nid, dst=nid)
            _label(cv, nid, name, x + LOOP_W + 8, y + LOOP_H / 2 + 11, "left")
        else:
            cv.edge([(lx[src], y), (lx[dst], y)], dashed, src=nid, dst=nid)
            _label(cv, nid, name, (lx[src] + lx[dst]) / 2, y)
        msgs.append((src, dst, nid))
        nodes.append({"id": nid, "name": name, "sub": symbol_of(s), "about": ctx.about.get(s["anchor"], ""), "anchor": anchor_link(s),
                      "detail": s["label"], "module": s["module"], "actor": s.get("actor"), "sources": s["sources"],
                      "lane": box[dst]["label"], "sym": symbol_of(s)})
    end = top + len(steps) * ROW
    for m in order:
        x, mod = lx[m], box[m]
        cv.back.append(f'<line class="l2" x1="{n(x)}" y1="{M + AH}" x2="{n(x)}" y2="{n(end)}" stroke-width="1" stroke-dasharray="{DASH}"/>')
        lines = wrap_name(mod["label"], AW - 16)
        base = M + (26 if len(lines) == 1 else 20)
        g = [f'<rect class="mask" x="{n(x - AW / 2)}" y="{M}" width="{AW}" height="{AH}" rx="6"/>'
             f'<rect class="nb{" focal" if m == order[0] else ""}" x="{n(x - AW / 2)}" y="{M}" width="{AW}" height="{AH}" rx="6" stroke-width="1"/>']
        for j, t in enumerate(lines):
            g.append(f'<text class="nm" x="{n(x)}" y="{n(base + 15 * j)}" font-size="13" font-weight="600" text-anchor="middle">{esc(t)}</text>')
        g.append(f'<text class="sb" x="{n(x)}" y="{n(M + AH - 8)}" font-size="10" text-anchor="middle">{esc(os.path.basename(mod["sources"][0]["path"])[:24])}</text>')
        cv.back.append("".join(g))
    legend = [("focal", "Entry lifeline"), ("line", "Call, in walk order"), ("dash", "Inferred call")]
    note = f"Lifelines are the caller, modules and stores; each message is the step of the same name on the {b['title']} swimlane board."
    lh = cv.legend(end + 28, W, legend, note)
    H = up4(end + 28 + lh + M)
    svg = cv.svg(W, H, b["title"] + " sequence", f"Sequence diagram, {len(steps)} messages over {len(order)} lifelines: " + ", ".join(m["name"] for m in nodes) + ".")
    return Board(id=bid, group="Runtime", title=fit(b["title"]), purpose=f"{b['title']}: {len(steps)} calls over {len(order)} lifeline{'s' * (len(order) > 1)}, in walk order.",
                 svg=svg, nodes=nodes, legend=legend, notes=[note], entry=nodes[0]["id"])


def build(ctx):
    fl = flows(ctx.doc)
    if not fl:
        return Board(id="sequence", group="Runtime", title="Sequence", purpose="Calls between modules, in walk order.", svg=empty_svg("No flows found"))
    return [board_for(ctx, b, st, ed) for b, st, ed in fl]
