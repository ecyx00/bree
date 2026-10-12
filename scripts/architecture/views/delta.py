"""Changes group: the architecture-delta board (diagram-design grammar): Before · Changes · After over the module topology. 0 LLM tokens.

Before model: git HEAD:.architecture/current.architecture.json when the repo tracks it, else current.architecture.prev.json (kept by gen.py on a full
or refresh run). The board records the before source fingerprint in `data-before-fp` on its <svg>; the native Changes tab (Swift) compares it with the
fingerprint it computes itself, and shows this board only while they match.

Objects: modules (overview nodes of kind module, id persists) and overview edges that are not hidden (the edge `id`, so a rewire is the same id with
other endpoints; the generator derives ids from the endpoints today, so a real run reports add + remove and a hand-written id shows REWIRED).
Position = level (distance from the foundations, the Layers board turned upside down). A retained module is MOVED when its level changes. Cells are a pure function of (level, sorted id), so
nothing else moves. Edges to or from an added or removed module are implied by it: they are not drawn or listed, the ledger line gives the count.
Budget (diagram-design): at most 8 modules, 10 relationships, 8 ledger entries; the rest is counted in a "+N more" line, never silently dropped.
"""
import hashlib, json, os, subprocess

from draw import Canvas, M, ortho, SMALL, NAME, DASH, EDGE_W, up4, n, esc, tw
from . import Board, empty_svg
from ._struct import layers

BOARD_ID = "delta"
MAX_COMP, MAX_REL, MAX_LEDGER = 8, 10, 8
PRIORITY = {"REWIRED": 0, "REMOVED": 1, "ADDED": 2, "CHANGED": 3, "MOVED": 4}
CW, CH, PAD, GUT, RGAP = 152, 88, 24, 144, 32       # component size, panel padding, edge gutter (12 lanes of 12), row gap: all multiples of 4
PW = PAD + CW + GUT + CW + PAD
LW, LINE = 340, 15                                   # ledger column width, line pitch
LEDGER_CHARS = 46
JSON_REL = ".architecture/current.architecture.json"
PREV_NAME = "current.architecture.prev.json"
CSS = ("#b-delta .nb.rm{stroke-dasharray:5,4}#b-delta .ed.add{stroke:var(--ink);stroke-width:1.8}"
       "#b-delta .ed.rw{stroke:var(--ink)}#b-delta .panel{fill:none;stroke:var(--rule)}#b-delta .hd{fill:var(--muted)}")


# ---------------------------------------------------------------- the before model
def prev_fingerprint(raw):
    return "prev:" + hashlib.sha256(raw).hexdigest()[:16]


def _git(root, *args):
    r = subprocess.run(["git", "-C", root, *args], capture_output=True, timeout=20)
    return r.stdout if r.returncode == 0 else None


def before_source(root, arch_dir):
    """-> {doc, kind: git|prev, fp, label} or None. git HEAD when the repo tracks the model file, else the prev file."""
    if root:
        blob = _git(root, "rev-parse", "HEAD:./" + JSON_REL)
        head = _git(root, "rev-parse", "HEAD")
        raw = _git(root, "show", "HEAD:./" + JSON_REL) if blob and head else None
        if raw:
            try:
                return {"doc": json.loads(raw), "kind": "git", "fp": f"git:{head.decode().strip()}:{blob.decode().strip()}", "label": "the last commit"}
            except ValueError:
                pass
    p = os.path.join(arch_dir or "", PREV_NAME)
    if arch_dir and os.path.exists(p):
        raw = open(p, "rb").read()
        try:
            return {"doc": json.loads(raw), "kind": "prev", "fp": prev_fingerprint(raw), "label": "the previous generation"}
        except ValueError:
            return None
    return None


# ---------------------------------------------------------------- the comparison
def snapshot(doc):
    mods = {x["id"]: {"id": x["id"], "name": x.get("label") or x["id"], "role": x.get("role", ""),
                      "path": (x.get("sources") or [{"path": ""}])[0]["path"]} for x in doc.get("nodes", []) if x.get("kind") == "module"}
    rels = {}
    for e in doc.get("edges", []):
        if e.get("board") == "overview" and "hidden" not in e and e["from"] in mods and e["to"] in mods and e["from"] != e["to"]:
            rels[e["id"]] = {"id": e["id"], "from": e["from"], "to": e["to"], "solid": bool(e.get("solid", True))}
    lay = layers(sorted(mods), sorted({(r["from"], r["to"]) for r in rels.values()}))
    top = max(lay.values(), default=0)
    for i, m in mods.items():
        m["layer"] = top - lay[i]   # level = distance from the foundations: only a change below a module moves it, a longer chain above does not
    return mods, rels


def _sig(m):
    return (m["name"], m["role"], m["path"])


def compare(before, after):
    """Change entries [{change, kind, target, text}] in a fixed order. text is the ledger sentence (without the leading word)."""
    mb, rb = snapshot(before)
    ma, ra = snapshot(after)
    out = []

    def add(change, kind, target, text, names=()):
        out.append({"change": change, "kind": kind, "target": target, "text": text, "names": list(names)})

    def links(rels, i):
        return sum(1 for r in rels.values() if i in (r["from"], r["to"]))

    for i in sorted(ma):
        if i not in mb:
            add("ADDED", "component", i, f"New module {ma[i]['path']}, {links(ra, i)} links", [ma[i]["name"]])
    for i in sorted(mb):
        if i not in ma:
            add("REMOVED", "component", i, f"Module gone, was {mb[i]['path']}, {links(rb, i)} links", [mb[i]["name"]])
    for i in sorted(set(mb) & set(ma)):
        b, a = mb[i], ma[i]
        diff = [f"{k}: {x} → {y}" for k, x, y in (("name", b["name"], a["name"]), ("role", b["role"] or "none", a["role"] or "none"), ("source", b["path"], a["path"])) if x != y]
        if diff:
            add("CHANGED", "component", i, "; ".join(diff), [a["name"]])
        if b["layer"] != a["layer"]:
            add("MOVED", "component", i, f"Level {b['layer']} → level {a['layer']} (distance from the foundations)", [a["name"]])
    gone = (set(mb) ^ set(ma))   # added or removed modules: their edges are implied by them

    def implied(r):
        return r["from"] in gone or r["to"] in gone

    def nm(mods, i):
        return mods[i]["name"]

    for i in sorted(set(rb) & set(ra)):
        b, a = rb[i], ra[i]
        if implied(b) or implied(a):
            continue
        if (b["from"], b["to"]) != (a["from"], a["to"]):
            add("REWIRED", "relationship", i, f"{nm(mb, b['from'])} → {nm(mb, b['to'])} became {nm(ma, a['from'])} → {nm(ma, a['to'])}")
        if b["solid"] != a["solid"]:
            add("CHANGED", "relationship", i, f"{'direct' if b['solid'] else 'inferred'} → {'direct' if a['solid'] else 'inferred'}")
    for i in sorted(set(ra) - set(rb)):
        if not implied(ra[i]):
            add("ADDED", "relationship", i, f"{nm(ma, ra[i]['from'])} → {nm(ma, ra[i]['to'])}")
    for i in sorted(set(rb) - set(ra)):
        if not implied(rb[i]):
            add("REMOVED", "relationship", i, f"{nm(mb, rb[i]['from'])} → {nm(mb, rb[i]['to'])}")
    return out


def select(changes, mb, rb, ma, ra):
    """Greedy pick under the budget. Returns (entries, comp ids, rel ids, hidden entry count). An object always comes with all its entries;
    a relationship also brings its endpoints (and their entries) so every drawn status has its ledger line."""
    by_obj = {}
    for c in changes:
        by_obj.setdefault(c["target"], []).append(c)
    order = sorted(by_obj, key=lambda o: (min(PRIORITY[c["change"]] for c in by_obj[o]), by_obj[o][0]["kind"] != "relationship", o))
    shown, comps, rels = [], set(), set()
    for o in order:
        objs = [o]
        if by_obj[o][0]["kind"] == "relationship":
            ends = {x for r in (rb.get(o), ra.get(o)) if r for x in (r["from"], r["to"])}
            objs += sorted(e for e in ends if e in by_obj)
        new_c = {x for x in objs if by_obj[x][0]["kind"] == "component"} | (
            {x for r in (rb.get(o), ra.get(o)) if r for x in (r["from"], r["to"])} if by_obj[o][0]["kind"] == "relationship" else set())
        new_r = {o} if by_obj[o][0]["kind"] == "relationship" else set()
        new_e = [c for x in objs if x not in shown_objs(shown) for c in by_obj[x]]
        if o in shown_objs(shown):
            continue
        if len(comps | new_c) > MAX_COMP or len(rels | new_r) > MAX_REL or len(shown) + len(new_e) > MAX_LEDGER:
            continue
        shown += new_e
        comps |= new_c
        rels |= new_r
    return shown, comps, rels, len(changes) - len(shown)


def shown_objs(entries):
    return {c["target"] for c in entries}


# ---------------------------------------------------------------- drawing
def clip(text, limit):
    return text if len(text) <= limit else text[:limit - 1] + "…"


def wrap_chars(text, limit, max_lines):
    lines, cur = [], ""
    for w in text.split():
        while len(w) > limit:   # a word longer than a line is cut, never allowed to overflow the node
            if cur:
                lines.append(cur)
                cur = ""
            lines.append(w[:limit])
            w = w[limit:]
        t = (cur + " " + w).strip()
        if cur and len(t) > limit:
            lines.append(cur)
            cur = w
        else:
            cur = t
    if cur:
        lines.append(cur)
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        lines[-1] = clip(lines[-1] + "…", limit)
    return lines or [""]


def tail(path, limit=19):
    return path if len(path) <= limit else "…" + path[-(limit - 1):]


TAGS = {"added": "+ ADDED", "removed": "− REMOVED", "changed": "Δ CHANGED", "moved": "↔ MOVED", "changed moved": "Δ↔ CHG+MOV"}


def component_g(snap, m, status, x, y, label):
    cx, cy = x + CW / 2, y + CH / 2
    nid = f"{BOARD_ID}:{snap}:{m['id']}"
    sig = f"name={m['name']};role={m['role']};src={m['path']}"
    g = [f'<g class="node" data-id="{esc(nid)}" tabindex="0" role="button" aria-label="{esc(m["name"])}" data-snapshot="{"before" if snap == "b" else "after"}" data-kind="component" data-object-id="{esc(m["id"])}" '
         f'data-status="{status}" data-signature="{esc(sig)}">',
         f'<rect class="mask" data-role="bounds" x="{x}" y="{y}" width="{CW}" height="{CH}" rx="6"/>',
         f'<rect class="nb{" rm" if status == "removed" else ""}" x="{x}" y="{y}" width="{CW}" height="{CH}" rx="6" stroke-width="1"/>']
    if status in TAGS:
        tg = TAGS[status]
        w = up4(tw(tg, SMALL, mono=True, track=0.06) + 12)
        g.append(f'<rect class="tag" x="{x + 12}" y="{y + 10}" width="{w}" height="18" rx="2" stroke-width="0.8"/>'
                 f'<text class="tg" x="{n(x + 12 + w / 2)}" y="{y + 23}" font-size="{SMALL}" text-anchor="middle">{esc(tg)}</text>')
    lines = wrap_chars(m["name"], 18, 2)
    base = y + (54 if len(lines) == 1 else 44)
    for j, t in enumerate(lines):
        g.append(f'<text class="nm" x="{n(cx)}" y="{base + 16 * j}" font-size="{NAME}" font-weight="600" text-anchor="middle">{esc(t)}</text>')
    g.append(f'<text class="sb" x="{n(cx)}" y="{y + 80}" font-size="{SMALL}" text-anchor="middle">{esc(tail(m["path"]))}</text></g>')
    return "".join(g)


def layout(comps, mb, ma):
    """-> (pos {(snap, id): (x, y)}, rows). Band per layer; cells by sorted id over the members of either snapshot; two columns."""
    bands = {}
    for snap, mods in (("b", mb), ("a", ma)):
        for i in comps:
            if i in mods:
                bands.setdefault(mods[i]["layer"], set()).add(i)
    pos, row0 = {}, 0
    for L in sorted(bands, reverse=True):   # the highest level (the entry side) is the top row
        mem = sorted(bands[L])
        for snap, mods in (("b", mb), ("a", ma)):
            for k, i in enumerate(mem):
                if i in mods and mods[i]["layer"] == L:
                    pos[(snap, i)] = (PAD + (k % 2) * (CW + GUT), PAD + (row0 + k // 2) * (CH + RGAP))
        row0 += -(-len(mem) // 2)
    return pos, row0


def panel(snap, mods, rels, comps, rel_ids, status, pos, rows, tx, ty, label):
    ph = PAD * 2 + rows * CH + (rows - 1) * RGAP
    # Flat on purpose: a <g transform> around the nodes breaks the shell's content box (getBBox ignores the transform) and check_svg's text sweep.
    # So the panel origin is baked into every coordinate (tx, ty are multiples of 4) and each element carries data-snapshot itself.
    g = [f'<rect class="panel" data-snapshot-frame="{"before" if snap == "b" else "after"}" data-grid="{PW} {ph} 4" x="{tx}" y="{ty}" width="{PW}" height="{ph}" rx="8" stroke-width="1"/>']
    drawn = [r for r in sorted(rels) if r in rel_ids]
    ports = {}
    for r in drawn:
        for end in ("from", "to"):
            ports.setdefault(rels[r][end], []).append((r, end))
    slot = {}
    for i, lst in ports.items():
        lst.sort(key=lambda t: (pos[(snap, rels[t[0]]["to" if t[1] == "from" else "from"])][1], t))
        step = min(12, 56 // max(1, len(lst) - 1)) if len(lst) > 1 else 12
        for k, (r, end) in enumerate(lst):
            slot[(r, end)] = ty + pos[(snap, i)][1] + CH / 2 + (k - (len(lst) - 1) / 2) * step
    for k, r in enumerate(drawn):
        e = rels[r]
        (fx, _), (tx2, _) = pos[(snap, e["from"])], pos[(snap, e["to"])]
        sx = tx + (fx + CW if fx == PAD else fx)
        ex = tx + (tx2 + CW if tx2 == PAD else tx2)
        lane = tx + PAD + CW + 12 * (k + 1)
        pts = [(sx, slot[(r, "from")]), (lane, slot[(r, "from")]), (lane, slot[(r, "to")]), (ex, slot[(r, "to")])]
        pts = [p for i, p in enumerate(pts) if i == 0 or p != pts[i - 1]]
        if len(pts) == 3 and pts[0][1] == pts[1][1] == pts[2][1]:
            pts = [pts[0], pts[2]]
        st = status[(snap, r)]
        cls = "ed" + (" add" if st == "added" else " rw" if "rewired" in st else "")
        dash = f' stroke-dasharray="{DASH}"' if st == "removed" else ' stroke-dasharray="2,4"' if "rewired" in st else ""
        sig = f"solid={int(e['solid'])}"
        g.append(f'<path class="{cls}" data-snapshot="{"before" if snap == "b" else "after"}" data-kind="relationship" data-object-id="{esc(r)}" data-status="{st}" data-signature="{sig}" data-from="{esc(e["from"])}" '
                 f'data-to="{esc(e["to"])}" d="{ortho(pts)}" stroke-width="{EDGE_W}"{dash} marker-end="url(#ardelta)"/>')
    for i in sorted(comps):
        if i in mods:
            x, y = pos[(snap, i)]
            g.append(component_g(snap, mods[i], status[(snap, i)], tx + x, ty + y, ""))
    return "".join(g), ph


def build(ctx):
    src = before_source(ctx.root, getattr(ctx, "arch_dir", None))
    base = dict(id=BOARD_ID, group="Changes", title="Changes")
    P = "What changed in the module topology since an earlier version."
    if src is None:
        return Board(**base, purpose=P, svg=_tag(empty_svg("No earlier version to compare with"), "none"))
    import render
    src["doc"] = render.fix_labels(src["doc"])   # the same humanized names as the current model, or every unnamed module would read as CHANGED
    changes = compare(src["doc"], ctx.doc)
    if not changes:
        return Board(**base, purpose=P, svg=_tag(empty_svg(f"No changes since {src['label']}"), src["fp"]))
    mb, rb = snapshot(src["doc"])
    ma, ra = snapshot(ctx.doc)
    entries, comps, rel_ids, hidden = select(changes, mb, rb, ma, ra)
    if not entries:
        return Board(**base, purpose=P, svg=_tag(empty_svg(f"{len(changes)} changes, too many to draw"), src["fp"]))
    kinds = {c["change"] for c in entries}
    purpose = f"{len(entries)} of {len(changes)} changes since {src['label']}." if hidden else f"{len(entries)} changes since {src['label']}."
    if kinds <= {"CHANGED"}:   # attributes only: no topology story, a ledger table says it better
        return _table(base, src, entries, hidden, purpose)
    return _topology(base, src, ctx, entries, comps, rel_ids, hidden, purpose, mb, rb, ma, ra)


def _tag(svg, fp):
    return svg.replace("<svg ", f'<svg data-before-fp="{esc(fp)}" ', 1)


def ledger_lines(c):
    head = f"{c['change']} {clip(c['names'][0], 28) if c['names'] else 'link'}"
    return [head] + wrap_chars(c["text"], LEDGER_CHARS, 3)


def ledger_text(c, x, y, extra=""):
    ls = ledger_lines(c)
    sp = f'<tspan>{esc(ls[0])}</tspan>' + "".join(f'<tspan x="{x}" dy="{LINE}">{esc(t)}</tspan>' for t in ls[1:])
    return (f'<text class="lg" data-change="{c["change"]}" data-target="{esc(c["target"])}" x="{x}" y="{y}" font-size="{SMALL}">{sp}</text>', len(ls) * LINE)


def _title_of(doc, label):
    return f"{label} · {(doc.get('generated_at') or '')[:10]} {doc.get('commit') or ''}".strip()


def _topology(base, src, ctx, entries, comps, rel_ids, hidden, purpose, mb, rb, ma, ra):
    status = {}
    ent = {}
    for c in entries:
        ent.setdefault(c["target"], set()).add(c["change"].lower())
    for snap, mods, rels in (("b", mb, rb), ("a", ma, ra)):
        for i in mods:
            s = ent.get(i, set())
            status[(snap, i)] = ("removed" if snap == "b" and i not in ma else "added" if snap == "a" and i not in mb
                                 else "changed moved" if {"changed", "moved"} <= s else next(iter(s), "unchanged"))
        for r in rels:
            s = ent.get(r, set())
            status[(snap, r)] = ("removed" if snap == "b" and r not in ra else "added" if snap == "a" and r not in rb
                                 else "changed rewired" if {"changed", "rewired"} <= s else next(iter(s), "unchanged"))
    # context: unchanged relationships between the shown modules (a changed one that did not make the cut stays out: it has no ledger line)
    both = sorted(r for r in set(rb) & set(ra) if r not in rel_ids and rb[r]["from"] in comps and rb[r]["to"] in comps and (rb[r]["from"], rb[r]["to"]) == (ra[r]["from"], ra[r]["to"])
                  and rb[r]["from"] in mb and rb[r]["from"] in ma and rb[r]["to"] in mb and rb[r]["to"] in ma and r not in ent)
    drawn = set(rel_ids) | set(both[:max(0, MAX_REL - len(rel_ids))])
    pos, rows = layout(comps, mb, ma)
    rows = max(rows, 1)
    cv = Canvas(BOARD_ID)
    top = 64
    gb, ph = panel("b", mb, rb, comps, drawn, status, pos, rows, M, top, "")
    ax = M + PW + 24 + LW + 24
    ga, _ = panel("a", ma, ra, comps, drawn, status, pos, rows, ax, top, "")
    W = ax + PW + M
    cv.back.append(f'<text class="eb" x="{M}" y="{M}" font-size="{SMALL}">BEFORE</text><text class="sb" x="{M + 76}" y="{M}" font-size="{SMALL}">{esc(clip(_title_of(src["doc"], src["label"]), 44))}</text>')
    cv.back.append(f'<text class="eb" x="{M + PW + 24}" y="{M}" font-size="{SMALL}">CHANGES</text>')
    cv.back.append(f'<text class="eb" x="{ax}" y="{M}" font-size="{SMALL}">AFTER</text><text class="sb" x="{ax + 64}" y="{M}" font-size="{SMALL}">{esc(clip(_title_of(ctx.doc, "now"), 44))}</text>')
    cv.back += [gb, ga]
    lx, ly = M + PW + 24, top + PAD
    for c in sorted(entries, key=lambda c: (PRIORITY[c["change"]], c["target"])):
        t, h = ledger_text(c, lx, ly + 12)
        cv.back.append(t)
        ly += h + 14
    if hidden:
        cv.back.append(f'<text class="lg" x="{lx}" y="{ly + 12}" font-size="{SMALL}">+{hidden} more changes not drawn (budget 8 modules, 10 links, 8 lines)</text>')
        ly += LINE + 14
    H = up4(max(top + ph, ly) + 24)
    items = [("box", "Module"), ("line", "Link"), ("dash", "Removed (dashed)")]
    note = "Tags: + added, − removed, Δ changed, ↔ moved (level). Dotted link = rewired. Links of added or removed modules are implied by them."
    lh = cv.legend(H, W, items, note)
    svg = cv.svg(W, up4(H + lh + M), "Architecture delta", f"{len(entries)} changes: before, change ledger, after.")
    svg = svg.replace("<svg ", f'<svg data-diagram="architecture-delta" data-before-fp="{esc(src["fp"])}" ', 1)
    nodes = []
    for snap, mods, lab in (("b", mb, "Before"), ("a", ma, "After")):
        for i in sorted(comps):
            if i in mods:
                m = mods[i]
                nodes.append({"id": f"{BOARD_ID}:{snap}:{i}", "name": m["name"], "sub": m["path"], "anchor": m["path"] + "#", "detail": f"{lab}: {status[(snap, i)]}.",
                              "about": m["role"]})
    return Board(**base, purpose=purpose, svg=svg, nodes=nodes, legend=items, notes=[note], css=CSS)


def _table(base, src, entries, hidden, purpose):
    cv = Canvas(BOARD_ID)
    W, c2 = 960, M + 300
    y = M
    cv.back.append(f'<text class="eb" x="{M}" y="{y}" font-size="{SMALL}">CHANGED</text><text class="eb" x="{c2}" y="{y}" font-size="{SMALL}">BEFORE → AFTER</text>'
                   f'<line class="l1" x1="{M}" y1="{y + 10}" x2="{W - M}" y2="{y + 10}" stroke-width="0.8"/>')
    y += 34
    for c in sorted(entries, key=lambda c: c["target"]):
        ls = ledger_lines(c)
        sp = f'<tspan>{esc(ls[0])}</tspan>' + "".join(f'<tspan x="{c2}" dy="{0 if j == 0 else LINE}">{esc(t)}</tspan>' for j, t in enumerate(ls[1:]))
        # first description line shares the head's baseline: tspan x jumps to column 2
        cv.back.append(f'<text class="lg" data-change="{c["change"]}" data-target="{esc(c["target"])}" x="{M}" y="{y}" font-size="{SMALL}">{sp}</text>')
        y += max(1, len(ls) - 1) * LINE + 14
    if hidden:
        cv.back.append(f'<text class="lg" x="{M}" y="{y}" font-size="{SMALL}">+{hidden} more changes not listed</text>')
        y += LINE + 14
    note = "Only attributes changed: no module or link was added, removed, moved or rewired."
    cv.back.append(f'<text class="lg" x="{M}" y="{y + 8}" font-size="{SMALL}">{esc(note)}</text>')
    svg = cv.svg(W, up4(y + 8 + M), "Architecture changes", f"{len(entries)} attribute changes.")
    return Board(**base, purpose=purpose, svg=_tag(svg, src["fp"]), nodes=[], notes=[note], css=CSS)
