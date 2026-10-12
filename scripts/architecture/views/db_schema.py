"""Data group: the physical database schema (diagram-design db-schema grammar). Tables, columns, PK/FK/UQ/NN chips, indexes and column-to-column
foreign keys, parsed from the CREATE TABLE / CREATE INDEX text found in the repo's source files. No LLM, 0 tokens.
A repo without such text gets the one-line empty state "No database schema found".
"""
import os, re
from collections import defaultdict

from draw import Canvas, M, SMALL, NAME, EDGE_W, up4, n, tw, esc, ortho, clean
from . import Board, empty_svg

BOARD_ID = "db-schema"
KW = r"(?:PRIMARY|NOT|NULL|UNIQUE|DEFAULT|REFERENCES|CHECK|COLLATE|GENERATED|AS|CONSTRAINT)\b"
_TABLE = re.compile(r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:["`\[]?\w+["`\]]?\.)?["`\[]?(\w+)["`\]]?\s*\(', re.I)
_INDEX = re.compile(r'CREATE\s+(UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:\w+\.)?["`]?(\w+)["`]?\s+ON\s+["`]?(\w+)["`]?\s*\(([^)]*)\)', re.I)
_REF = re.compile(r'REFERENCES\s+["`]?(\w+)["`]?\s*(?:\(\s*["`]?(\w+)["`]?\s*\))?(.*)', re.I | re.S)
_ACT = re.compile(r'ON\s+DELETE\s+(CASCADE|RESTRICT|SET\s+NULL|SET\s+DEFAULT|NO\s+ACTION)', re.I)


def _body(text, i):
    """Text between the paren that opens at text[i-1] and its match (quotes respected); None if unbalanced."""
    d, q = 1, None
    for j in range(i, len(text)):
        c = text[j]
        if q:
            q = None if c == q else q
        elif c in "'\"":
            q = c
        elif c == "(":
            d += 1
        elif c == ")":
            d -= 1
            if d == 0:
                return text[i:j]
    return None


def _split(body):
    parts, d, cur = [], 0, ""
    for c in body:
        d += (c == "(") - (c == ")")
        if c == "," and d == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += c
    return [p.strip() for p in parts + [cur] if p.strip()]


def _cols(s):
    return [c.strip().strip('"`[]') for c in s.split(",") if c.strip()]


def _fk(rest):
    m = _REF.search(rest)
    if not m:
        return None
    a = _ACT.search(m.group(3))
    return (m.group(1), m.group(2) or "", ("ON DELETE " + re.sub(r"\s+", " ", a.group(1).upper())) if a else "")


def parse_schema(text):
    """-> (tables, indexes). Virtual tables are skipped. Each table: {name, columns: [{name, type, pk, nn, uq, fk}], pk: [col]}."""
    tables = []
    for m in _TABLE.finditer(text):
        body = _body(text, m.end())
        if body is None:
            continue
        body = re.sub(r"--[^\n]*", "", body)
        cols, pk, fks = [], [], []
        for part in _split(body):
            up = part.upper()
            if re.match(r"(CONSTRAINT\s+\w+\s+)?(PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK)\s*\(", up):
                if "PRIMARY KEY" in up.split("(")[0]:
                    pk = _cols(part[part.index("(") + 1:part.rindex(")")])
                elif "FOREIGN KEY" in up.split("(")[0]:
                    mm = re.search(r"\(([^)]*)\)\s*(REFERENCES.*)", part, re.I | re.S)
                    if mm and _fk(mm.group(2)):
                        fks.append((_cols(mm.group(1)), _fk(mm.group(2))))
                continue
            if up.startswith("CONSTRAINT"):
                continue
            nm = re.match(r'["`\[]?(\w+)["`\]]?\s*(.*)', part, re.S)
            if not nm:
                continue
            rest = nm.group(2)
            ty = re.match(r"([A-Za-z_]+(?:\s*\(\s*\d+(?:\s*,\s*\d+)?\s*\))?)", rest)
            ty = "" if (not ty or re.match(KW, ty.group(1), re.I)) else re.sub(r"\s+", "", ty.group(1)) if "(" in ty.group(1) else ty.group(1)
            cols.append({"name": nm.group(1), "type": ty, "pk": bool(re.search(r"PRIMARY\s+KEY", rest, re.I)),
                         "nn": bool(re.search(r"NOT\s+NULL", rest, re.I)), "uq": bool(re.search(r"\bUNIQUE\b", rest, re.I)), "fk": _fk(rest)})
        for c in cols:
            if c["pk"] and c["name"] not in pk:
                pk.append(c["name"])
        for c in cols:
            c["pk"] = c["name"] in pk
        for names, f in fks:
            if len(names) == 1:
                for c in cols:
                    if c["name"] == names[0] and not c["fk"]:
                        c["fk"] = f
        tables.append({"name": m.group(1), "columns": cols, "pk": pk})
    idx = [{"name": m.group(2), "table": m.group(3), "cols": [re.sub(r"\s+(ASC|DESC)$", "", c, flags=re.I) for c in _cols(m.group(4))], "unique": bool(m.group(1))}
           for m in _INDEX.finditer(text)]
    return tables, idx


CODE_EXT = {".py", ".ts", ".tsx", ".js", ".mjs", ".sql", ".swift", ".go", ".rs", ".rb", ".java", ".kt", ".php", ".cs"}
SKIP_DIRS = {"bench", "benchmarks", "docs", "tests", "test", "examples", "node_modules", "__pycache__", "dist", "build", "vendor", "target", "Pods"}


def scan(root):
    """Parse every code file under root that mentions CREATE TABLE. -> (tables with 'src', indexes); the first definition of a name wins."""
    seen, tables, idx = set(), [], []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS and not x.startswith("."))
        for f in sorted(files):
            if os.path.splitext(f)[1] not in CODE_EXT:
                continue
            p = os.path.join(d, f)
            try:
                if os.path.getsize(p) > 2_000_000:
                    continue
                text = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if "CREATE" not in text.upper():
                continue
            ts, ix = parse_schema(text)
            rel = os.path.relpath(p, root)
            for t in ts:
                if t["name"] not in seen:
                    seen.add(t["name"])
                    tables.append(dict(t, src=rel))
            idx += [i for i in ix if i not in idx]
    return tables, [i for i in idx if i["table"] in seen]


# ---------------------------------------------------------------- drawing
RH, HH, MAXROWS, MAXTABLES, MAXFK, NC = 24, 32, 8, 24, 12, 3
GXD, OUT = 64, 64
LANES_IN = (-6, 6, -18, 18)


def _shown(t, need):
    cols = t["columns"]
    if len(cols) <= MAXROWS:
        return cols
    must = [c for c in cols if c["pk"] or c["fk"] or c["name"] in need][:MAXROWS]
    pick = {c["name"] for c in must}
    for c in cols:
        if len(pick) < MAXROWS and c["name"] not in pick:
            pick.add(c["name"])
    return [c for c in cols if c["name"] in pick]


def _chips(c):
    return [k for k, on in (("PK", c["pk"]), ("FK", bool(c["fk"])), ("UQ", c["uq"])) if on]


def _chip_w(k):
    return up4(tw(k, SMALL, mono=True, track=0.06) + 10)


def _need_w(t, rows, ixs):
    w = 0
    for c in rows:
        w = max(w, 12 + tw(c["name"], 12) + 12 + sum(_chip_w(k) + 6 for k in _chips(c)) + 12 + tw(c["type"], SMALL, mono=True) + 12)
    return max(w, 12 + tw(t["name"], NAME, bold=True) + 16 + _chip_w("TABLE") + 12, 12 + max([tw(i["name"], SMALL, mono=True) for i in ixs] + [0]) + 12)


def _table(cv, nid, x, y, w, h, t, rows, ixs, accent):
    cv.rects.append((x, y, x + w, y + h))
    g = [f'<g class="node" data-id="{esc(nid)}" tabindex="0" role="button" aria-label="{esc(t["name"])}">',
         f'<rect class="mask" x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}" rx="6"/>',
         f'<rect class="nb tb" x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}" rx="6" stroke-width="1"/>',
         f'<path class="hd{" cs" if accent else ""}" d="M{n(x + 0.5)},{n(y + HH)}V{n(y + 6)}Q{n(x + 0.5)},{n(y + 0.5)} {n(x + 6)},{n(y + 0.5)}H{n(x + w - 6)}Q{n(x + w - 0.5)},{n(y + 0.5)} {n(x + w - 0.5)},{n(y + 6)}V{n(y + HH)}Z" stroke="none"/>',
         f'<text class="nm" x="{n(x + 12)}" y="{n(y + 21)}" font-size="{NAME}" font-weight="600">{esc(t["name"])}</text>']
    tw_ = _chip_w("TABLE")
    g.append(f'<rect class="tag" x="{n(x + w - 12 - tw_)}" y="{n(y + 7)}" width="{n(tw_)}" height="18" rx="2" stroke-width="0.8"/>'
             f'<text class="tg" x="{n(x + w - 12 - tw_ / 2)}" y="{n(y + 20)}" font-size="{SMALL}" text-anchor="middle">TABLE</text>')
    g.append(f'<line class="l2" x1="{n(x)}" y1="{n(y + HH)}" x2="{n(x + w)}" y2="{n(y + HH)}" stroke-width="0.8"/>')
    for i, c in enumerate(rows):
        ry = y + HH + i * RH
        if i % 2:
            g.append(f'<rect class="alt" x="{n(x + 1)}" y="{n(ry)}" width="{n(w - 2)}" height="{RH}"/>')
        g.append(f'<text class="nm" x="{n(x + 12)}" y="{n(ry + 16)}" font-size="12">{esc(c["name"])}</text>')
        cx = x + 12 + tw(c["name"], 12) + 12
        for k in _chips(c):
            cw = _chip_w(k)
            g.append(f'<rect class="tag" x="{n(cx)}" y="{n(ry + 3)}" width="{n(cw)}" height="18" rx="2" stroke-width="0.8"/>'
                     f'<text class="tg" x="{n(cx + cw / 2)}" y="{n(ry + 16)}" font-size="{SMALL}" text-anchor="middle">{k}</text>')
            cx += cw + 6
        if c["type"]:
            g.append(f'<text class="sb" x="{n(x + w - 12)}" y="{n(ry + 16)}" font-size="{SMALL}" text-anchor="end">{esc(c["type"])}</text>')
    yy = y + HH + RH * len(rows)
    if len(rows) < len(t["columns"]):
        g.append(f'<text class="sb" x="{n(x + 12)}" y="{n(yy + 16)}" font-size="{SMALL}">+ {len(t["columns"]) - len(rows)} more columns</text>')
        yy += RH
    if ixs:
        g.append(f'<line class="l2" x1="{n(x)}" y1="{n(yy + 4)}" x2="{n(x + w)}" y2="{n(yy + 4)}" stroke-width="0.8"/>'
                 f'<text class="eb" x="{n(x + 12)}" y="{n(yy + 22)}" font-size="{SMALL}">INDEXES</text>')
        for j, i in enumerate(ixs[:3]):
            g.append(f'<text class="sb" x="{n(x + 12)}" y="{n(yy + 42 + 20 * j)}" font-size="{SMALL}">{esc(("UQ " if i["unique"] else "") + i["name"])}</text>')
        if len(ixs) > 3:
            g.append(f'<text class="sb" x="{n(x + 12)}" y="{n(yy + 42 + 60)}" font-size="{SMALL}">+ {len(ixs) - 3} more indexes</text>')
    g.append("</g>")
    cv.nodes.append("".join(g))


def _height(rows, t, ixs):
    return HH + RH * len(rows) + (RH if len(rows) < len(t["columns"]) else 0) + (0 if not ixs else 30 + 20 * min(3, len(ixs)) + (20 if len(ixs) > 3 else 0))


def build(ctx):
    tables, indexes = scan(ctx.root) if ctx.root else ([], [])
    if not tables:
        return Board(id=BOARD_ID, group="Data", title="DB schema", purpose="Tables, columns, keys and indexes.", svg=empty_svg("No database schema found"))
    tables.sort(key=lambda t: (t["src"], t["name"]))
    cap = len(tables) - MAXTABLES
    tables = tables[:MAXTABLES]
    by = {t["name"]: t for t in tables}
    # foreign keys: column row to column row, both tables and columns must exist
    fks, skipped = [], 0
    need = defaultdict(set)
    for t in tables:
        for c in t["columns"]:
            if c["fk"] and c["fk"][0] in by:
                tc = c["fk"][1] or (by[c["fk"][0]]["pk"] or [""])[0]
                if any(x["name"] == tc for x in by[c["fk"][0]]["columns"]):
                    fks.append((t["name"], c["name"], c["fk"][0], tc, c["fk"][2]))
                    need[t["name"]].add(c["name"])
                    need[c["fk"][0]].add(tc)
    ixs = defaultdict(list)
    for i in indexes:
        ixs[i["table"]].append(i)
    rows = {t["name"]: _shown(t, need[t["name"]]) for t in tables}
    ncol = min(NC + (len(tables) >= 13), len(tables))
    TW = int(min(360, max(240, max(up4(_need_w(t, rows[t["name"]], ixs[t["name"]])) for t in tables))))
    pos, shelf = {}, defaultdict(list)
    for k, t in enumerate(tables):
        shelf[k // ncol].append(t["name"])
    nrow = len(shelf)
    H_ = {t["name"]: _height(rows[t["name"]], t, ixs[t["name"]]) for t in tables}
    for r, mem in shelf.items():
        for c, nm_ in enumerate(mem):
            pos[nm_] = (c, r)
    xs0 = M + OUT
    W = xs0 + ncol * TW + (ncol - 1) * GXD + OUT + M
    colx = lambda c: xs0 + c * (TW + GXD)
    # edge plan: sides, gutters, row-gap channels
    plan, ends, cnt = [], defaultdict(int), defaultdict(int)
    for (s, sc, t_, tc, act) in fks:
        (cs, rs), (ct, rt) = pos[s], pos[t_]
        side_s = "r" if ct > cs else "l"
        side_t = "l" if ct > cs else "r"
        if ct == cs:
            side_s = side_t = "l"
        if ends[(s, sc, side_s)] >= 2 or ends[(t_, tc, side_t)] >= 2 or len(plan) >= MAXFK:
            skipped += 1
            continue
        ends[(s, sc, side_s)] += 1
        ends[(t_, tc, side_t)] += 1
        gs = cs + 1 if side_s == "r" else cs
        gt = ct if side_t == "l" else ct + 1
        gap = None
        if gs != gt:
            gap = rs if rt >= rs else rs - 1
            cnt[gap] += 1
        plan.append(dict(s=s, sc=sc, t=t_, tc=tc, act=act, ss=side_s, st=side_t, gs=gs, gt=gt, gap=gap, c=cnt[gap] - 1 if gap is not None else 0,
                         os=ends[(s, sc, side_s)] - 1, ot=ends[(t_, tc, side_t)] - 1))
    gaph = lambda g: max(48, 28 + 14 * cnt[g]) if cnt[g] else 48
    ty, y = {}, M
    for r in range(nrow):
        rh = max(H_[m] for m in shelf[r])
        for m in shelf[r]:
            ty[m] = y
        shelf_h = rh
        y += shelf_h + (gaph(r) if r < nrow - 1 else 0)
    cv = Canvas(BOARD_ID)
    cv.mk_b = cv.mk + "b"
    target_cascade = {p["t"] for p in plan if "CASCADE" in p["act"]}
    for t in tables:
        c, r = pos[t["name"]]
        _table(cv, f"{BOARD_ID}:{t['name']}", colx(c), ty[t["name"]], TW, H_[t["name"]], t, rows[t["name"]], ixs[t["name"]], t["name"] in target_cascade)
    lanes = defaultdict(list)

    def gx(g, k):
        if g == 0:
            return xs0 - 12 - 12 * k
        if g == ncol:
            return xs0 + ncol * TW + (ncol - 1) * GXD + 12 + 12 * k
        return xs0 + g * TW + (g - 1) * GXD + GXD / 2 + LANES_IN[k]

    def take(g, y0, y1):
        for k in range(4):
            if all(y1 + 14 < a or y0 - 14 > b for a, b in lanes[(g, k)]):
                lanes[(g, k)].append((y0, y1))
                return gx(g, k)
        return None

    def rowy(tn, col, off):
        i = next(i for i, c in enumerate(rows[tn]) if c["name"] == col)
        return ty[tn] + HH + RH * i + RH / 2 + (-6 if off == 0 else 6)
    labels, drawn = [], 0
    for p in plan:
        ys, yt = rowy(p["s"], p["sc"], p["os"]), rowy(p["t"], p["tc"], p["ot"])
        cs, ct = pos[p["s"]][0], pos[p["t"]][0]
        xs_ = colx(cs) + (TW if p["ss"] == "r" else 0)
        xt_ = colx(ct) + (TW if p["st"] == "r" else 0)
        if p["gap"] is None:
            lx = take(p["gs"], min(ys, yt), max(ys, yt))
            pts = None if lx is None else [(xs_, ys), (lx, ys), (lx, yt), (xt_, yt)]
        else:
            g = p["gap"]
            ych = (ty[shelf[g][0]] + max(H_[m] for m in shelf[g]) + 20 + 14 * p["c"]) if g >= 0 else M + 20
            l1, l2 = take(p["gs"], min(ys, ych), max(ys, ych)), take(p["gt"], min(yt, ych), max(yt, ych))
            pts = None if l1 is None or l2 is None else [(xs_, ys), (l1, ys), (l1, ych), (l2, ych), (l2, yt), (xt_, yt)]
        if pts is None:
            skipped += 1
            continue
        pts = clean(pts)
        cas = "CASCADE" in p["act"]
        cv.edges.append(f'<path class="ed{" cs" if cas else ""}" data-from="{esc(BOARD_ID + ":" + p["s"])}" data-to="{esc(BOARD_ID + ":" + p["t"])}" d="{ortho(pts)}" stroke-width="{EDGE_W}"'
                        + f' marker-end="url(#{cv.mk_b if cas else cv.mk})"><title>{esc(p["s"] + "." + p["sc"] + " -> " + p["t"] + "." + p["tc"] + (" " + p["act"] if p["act"] else ""))}</title></path>')
        cv.segs.append(pts)
        drawn += 1
        if p["act"]:
            labels.append((pts, p["act"], cas))
    end = max(ty[m] + H_[m] for m in ty) + 16
    for pts, act, cas in labels:
        words = act.replace("ON DELETE ", "").split()
        if cv.place_label(pts, ["ON DELETE"] + [" ".join(words)], (W, end)) and cas:
            cv.labels[-1] = cv.labels[-1].replace('class="al"', 'class="al cs"')
    nidx = sum(len(v) for v in ixs.values())
    note = " ".join(t for t in (
        f"Parsed from CREATE TABLE text in {len({t['src'] for t in tables})} source file(s).",
        f"{cap} more tables are not drawn." if cap > 0 else "", f"{skipped} foreign key(s) not drawn (too many ends or no free lane)." if skipped else "",
        "No foreign keys are declared in the schema text." if not fks else "") if t)
    items = [("box", "Table")] + ([("line", "Foreign key, column to column")] if drawn else [])
    lh = cv.legend(end, W, items, note)
    svg = cv.svg(W, up4(end + lh + M), "DB schema", f"{len(tables)} tables with columns, keys and indexes.")
    if any("CASCADE" in p["act"] for p in plan):
        svg = svg.replace("</defs>", f'<marker id="{cv.mk_b}" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon class="arb" points="0 0, 8 3, 0 6"/></marker></defs>', 1)
    refd = defaultdict(list)
    for (s, sc, t_, tc, act) in fks:
        refd[t_].append(s)
    nodes = []
    for t in tables:
        nm_ = t["name"]
        nodes.append({"id": f"{BOARD_ID}:{nm_}", "name": nm_, "sub": t["src"], "about": "", "anchor": t["src"] + "#",
                      "detail": f"{len(t['columns'])} columns ({', '.join(c['name'] for c in t['columns'][:12])}{', ...' if len(t['columns']) > 12 else ''}); "
                                f"primary key {', '.join(t['pk']) or 'none'}; {len(ixs[nm_])} index(es)." + (f" Referenced by {', '.join(sorted(set(refd[nm_])))}." if refd[nm_] else "")})
    ncols = sum(len(t["columns"]) for t in tables)
    css = ("#b-db-schema .hd{fill:color-mix(in srgb,var(--ink) 5%,transparent)}#b-db-schema .hd.cs{fill:var(--accent-tint)}"
           "#b-db-schema .alt{fill:color-mix(in srgb,var(--ink) 3%,transparent)}#b-db-schema .nb.tb{fill:var(--paper)}"
           "#b-db-schema path.ed.cs{stroke:var(--accent)}#b-db-schema .arb{fill:var(--accent)}#b-db-schema .al.cs{fill:var(--accent)}")
    return Board(id=BOARD_ID, group="Data", title="DB schema", purpose=f"{len(tables)} tables, {ncols} columns, {len(fks)} foreign key{"s" if len(fks) != 1 else ""}, {nidx} index{'es' if nidx != 1 else ''}, read from CREATE TABLE text.",
                 svg=svg, nodes=nodes, legend=items, notes=[note] if note else [], css=css)
