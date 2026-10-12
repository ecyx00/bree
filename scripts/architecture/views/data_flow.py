"""Runtime group: one data-flow board per flow that touches storage. Role lanes (caller, logic, store) as columns-by-step grid; each storage step
carries its db / fs / git primitive and whether the step body shows a read, a write or both (0 tokens, evidence from the source, never guessed)."""
from draw import Canvas, M, SMALL, FNAME, FSUB, esc, n, tw, up4, wrap_name, group_of, name_of, symbol_of, LANE_PAD
from . import Board, empty_svg
from ._runtime import flows, fit, slug, anchor_link, step_text, access_of, walk_evidence, STORE_TAG

NW, NH, GAPX, LW = 168, 88, 40, 120
PITCH = NW + GAPX
EDGE_END = 20


def access(ctx, s, found=()):
    """(tag, access, evidence lines) of a step. A storage step (actor Index / Files / Git) reads its own body (plus tiny callees); any step also
    takes the evidence `found` in the callees below it that are not picked steps (see _runtime.walk_evidence), a write winning over a read."""
    a = s.get("actor", "tool")
    own = access_of(a, step_text(ctx, s)) if group_of(a) == 2 else None
    ev = [(k, h, w) for k, h, w in found if h == "WRITE"] or [(k, h, w) for k, h, w in found if h == "READ"]
    if own is None and not ev:
        return ("CALLER" if group_of(a) == 0 else "LOGIC"), None, []
    kind = a if own else ev[0][0]
    hows = {h for k, h, w in found if k == kind} | set((own or "").replace("ACCESS", "").split("/")) - {""}
    acc = "READ/WRITE" if hows == {"READ", "WRITE"} and kind != "Git" else "WRITE" if "WRITE" in hows else "READ" if hows else "ACCESS"
    lines = [f"{STORE_TAG[k]} {h.lower()} in {w}" for k, h, w in ev if w != f"{s['sources'][0]['path']}:{s['anchor'].rsplit(':', 1)[1].split('#')[0]}"][:3]
    return f"{STORE_TAG[kind]} {acc}", acc, lines


def board_for(ctx, b, steps, edges):
    names = ctx.names
    sid = {s["id"]: s for s in steps}
    groups = sorted({group_of(s.get("actor", "tool")) for s in steps})
    lane_of = {s["id"]: groups.index(group_of(s.get("actor", "tool"))) for s in steps}
    nl = len(groups)
    bid = "data-" + slug(b["id"])
    cv = Canvas(bid)
    found = walk_evidence(ctx, steps)
    lane_h = NH + 2 * LANE_PAD
    PH = 28
    x0 = M + LW + 20
    W = up4(x0 + len(steps) * PITCH - GAPX + 20 + M)
    end = M + PH + nl * lane_h
    cx = {s["id"]: x0 + k * PITCH + NW / 2 for k, s in enumerate(steps)}
    cy = {s["id"]: M + PH + lane_of[s["id"]] * lane_h + lane_h / 2 for s in steps}
    for k in range(nl + 1):
        y = M + PH + k * lane_h
        cv.back.append(f'<line class="{"l2" if k in (0, nl) else "l1"}" x1="{M}" y1="{n(y)}" x2="{n(W - M)}" y2="{n(y)}" stroke-width="1"/>')
    cv.back.append(f'<line class="l2" x1="{n(M + LW)}" y1="{M + PH}" x2="{n(M + LW)}" y2="{n(end)}" stroke-width="1"/>')
    for k, gi in enumerate(groups):
        acts = sorted({s.get("actor", "tool") for s in steps if group_of(s.get("actor", "tool")) == gi} - {"tool"})
        if gi == 2:
            acts = [a for a in acts if a in STORE_TAG]
        words = [ctx.doc["repo"]] if gi == 1 else [(STORE_TAG[a] + " STORE") if gi == 2 else a for a in acts]
        lines = []
        for ln in words:
            cur = ""
            for w in ln.split():
                if cur and len(cur + " " + w) > 11:
                    lines.append(cur.upper())
                    cur = w
                else:
                    cur = (cur + " " + w).strip()
            lines.append(cur.upper())
        y = M + PH + k * lane_h + lane_h / 2 - 8 * (len(lines) - 1) + 4
        for j, t in enumerate(lines):
            cv.back.append(f'<text class="eb" x="{M}" y="{n(y + 16 * j)}" font-size="{SMALL}">{esc(t)}</text>')
    nodes = []
    for k, s in enumerate(steps):
        i = s["id"]
        nid = bid + ":" + i.split(":", 1)[1]
        tag, acc, ev = access(ctx, s, found[s["id"]])
        name, sym = name_of(s, names), symbol_of(s)
        x, y = cx[i] - NW / 2, cy[i] - NH / 2
        cv.rects.append((x, y, x + NW, y + NH))
        cls = "nb focal" if acc and "WRITE" in acc else ("nb store" if acc else "nb")
        tww = up4(tw(tag, SMALL, mono=True, track=0.06) + 12)
        g = [f'<g class="node" data-id="{esc(nid)}" tabindex="0" role="button" aria-label="{esc(name)}">'
             f'<rect class="mask" x="{n(x)}" y="{n(y)}" width="{NW}" height="{NH}" rx="6"/>'
             f'<rect class="{cls}" x="{n(x)}" y="{n(y)}" width="{NW}" height="{NH}" rx="6" stroke-width="1"/>'
             f'<rect class="tag" x="{n(x + 12)}" y="{n(y + 8)}" width="{n(tww)}" height="18" rx="2" stroke-width="0.8"/>'
             f'<text class="tg" x="{n(x + 12 + tww / 2)}" y="{n(y + 21)}" font-size="{SMALL}" text-anchor="middle">{esc(tag)}</text>']
        lines = wrap_name(name, NW - 16)
        for j, t in enumerate(lines):
            g.append(f'<text class="nm" x="{n(cx[i])}" y="{n(y + 42 + 15 * j)}" font-size="{FNAME}" font-weight="600" text-anchor="middle">{esc(t)}</text>')
        g.append(f'<text class="sb" x="{n(cx[i])}" y="{n(y + NH - 8)}" font-size="{FSUB}" text-anchor="middle">{esc(sym)}</text></g>')
        cv.nodes.append("".join(g))
        cv.back.append(f'<text class="eb" x="{n(cx[i])}" y="{M + 18}" font-size="{SMALL}" text-anchor="middle">{k + 1:02d}</text>')
        nodes.append({"id": nid, "name": name, "sub": sym, "about": ctx.about.get(s["anchor"], ""), "anchor": anchor_link(s),
                      "detail": s["label"] + (f" ({tag.lower()})" if acc else "") + ("".join(f"; {e}" for e in ev)), "module": s["module"], "actor": s.get("actor"), "sources": s["sources"],
                      "lane": tag, "sym": sym, "access": acc})
    flow = {(e["from"], e["to"]): e for e in edges}
    for a, c in zip(steps, steps[1:]):
        ia, ib = a["id"], c["id"]
        e = flow.get((ia, ib))
        sx, tx = cx[ia] + NW / 2, cx[ib] - NW / 2
        xv = sx + GAPX / 2
        pts = [(sx, cy[ia]), (tx, cy[ib])] if cy[ia] == cy[ib] else [(sx, cy[ia]), (xv, cy[ia]), (xv, cy[ib]), (tx, cy[ib])]
        cv.edge(pts, not (e and e.get("solid", True)), src=bid + ":" + ia.split(":", 1)[1], dst=bid + ":" + ib.split(":", 1)[1])
    legend = [("box", "Logic step"), ("focal", "Writes data"), ("store", "Reads data"), ("line", "Data passes on"), ("dash", "Inferred hand-off")]
    nw = sum(1 for m in nodes if m["access"] and "WRITE" in m["access"])
    note = f"{nw} of {len(steps)} steps write; a step is marked WRITE only when its code shows a write primitive."
    lh = cv.legend(end + 32, W, legend, note)
    H = up4(end + 32 + lh + M)
    svg = cv.svg(W, H, b["title"] + " data flow", f"Data flow, {len(steps)} steps in {nl} lanes; {nw} write storage.")
    return Board(id=bid, group="Runtime", title=fit(b["title"], "Data "), purpose=f"{b['title']}: where data is read and written ({nw} writing steps).",
                 svg=svg, nodes=nodes, legend=legend, notes=[note], entry=nodes[0]["id"])


def build(ctx):
    fl = [f for f in flows(ctx.doc) if any(group_of(s.get("actor", "tool")) == 2 for s in f[1]) or any(walk_evidence(ctx, f[1]).values())]
    if not fl:
        return Board(id="data-flow", group="Runtime", title="Data flow", purpose="Where data is read and written.", svg=empty_svg("No storage access found in the flows"))
    return [board_for(ctx, b, st, ed) for b, st, ed in fl]
