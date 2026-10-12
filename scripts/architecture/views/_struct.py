"""Shared helpers of the structure views (layers, nested, dependency): module units, cycles, layer ranks. Not a view (no build, not in REGISTRY).

Units are the overview's modules (doc nodes of kind "module", same labels as the Components board). A repo whose overview has none (for
example a TypeScript repo that was never generated) falls back to directory units read from the code-index graph, so the boards still show
real structure. Everything is sorted before it is iterated: the output is a pure function of the model.
"""
from collections import defaultdict

MAX_UNITS = 16                      # a board over this keeps the 16 busiest units and says so in its note
NON_CODE = {None, "", "json", "markdown", "make", "yaml", "toml", "text", "html", "css"}


# ---------------------------------------------------------------- pure graph helpers
def _succ(nodes, edges):
    s = {n: [] for n in nodes}
    for a, b in sorted(set(edges)):
        if a in s and b in s and a != b:
            s[a].append(b)
    return s


def split_back(nodes, edges):
    """DFS from the sorted nodes; an edge to a node still on the stack is a back edge. Returns (forward, back), both sorted."""
    succ = _succ(sorted(nodes), edges)
    state, back = {}, []

    def dfs(u):
        state[u] = 1
        for v in succ[u]:
            if state.get(v) == 1:
                back.append((u, v))
            elif v not in state:
                dfs(v)
        state[u] = 2

    for u in sorted(nodes):
        if u not in state:
            dfs(u)
    bs = set(back)
    return sorted(e for e in {(a, b) for a, b in edges if a != b and a in succ and b in succ} if e not in bs), sorted(back)


def find_cycles(nodes, edges):
    """Strongly connected components with 2+ nodes (Tarjan), each as a list in DFS order. Sorted, so the output is stable."""
    succ = _succ(sorted(nodes), edges)
    idx, low, on, stack, out, k = {}, {}, set(), [], [], [0]

    def go(u):
        idx[u] = low[u] = k[0]
        k[0] += 1
        stack.append(u)
        on.add(u)
        for v in succ[u]:
            if v not in idx:
                go(v)
                low[u] = min(low[u], low[v])
            elif v in on:
                low[u] = min(low[u], idx[v])
        if low[u] == idx[u]:
            comp = []
            while True:
                w = stack.pop()
                on.discard(w)
                comp.append(w)
                if w == u:
                    break
            if len(comp) > 1:
                out.append(sorted(comp, key=lambda x: idx[x]))

    for u in sorted(nodes):
        if u not in idx:
            go(u)
    return sorted(out)


def layers(nodes, edges):
    """Row of every node, 0 = top. Foundations (nothing below them) sit in the last row; every forward import points to a lower row.
    Row = (longest chain below the node) counted from the bottom, so a leaf utility is never pulled up to the entry row."""
    fwd, _ = split_back(nodes, edges)
    succ = _succ(sorted(nodes), fwd)
    h = {}

    def height(u):
        if u not in h:
            h[u] = 0 if not succ[u] else 1 + max(height(v) for v in succ[u])
        return h[u]

    for u in sorted(nodes):
        height(u)
    top = max(h.values(), default=0)
    return {u: top - h[u] for u in nodes}


def fan_in(nodes, edges):
    c = defaultdict(set)
    for a, b in edges:
        if a != b and a in nodes and b in nodes:
            c[b].add(a)
    return {n: len(c[n]) for n in nodes}


# ---------------------------------------------------------------- units from the model
def units(ctx):
    """-> (units {id: {label, path, role, files}}, edges [(a, b)] a imports/calls b, note). id is stable and unique per repo."""
    mods = sorted((x for x in ctx.doc["nodes"] if x["kind"] == "module"), key=lambda x: x["id"])
    if mods:
        u = {m["id"]: {"label": m["label"], "path": m["sources"][0]["path"], "role": m.get("role", ""), "files": 1} for m in mods}
        e = sorted({(x["from"], x["to"]) for x in ctx.doc["edges"] if x["board"] == "overview" and x["from"] in u and x["to"] in u and x["from"] != x["to"]})
        return _cap(u, e)
    try:
        return _cap(*_dir_units(ctx.graph))
    except Exception:  # no code index: the view shows its empty state
        return {}, [], ""


def _dir_units(g):
    import re
    from gen import IGNORE_DIRS
    files = [(i, p) for i, p, lang in g.db.execute("select id,path,lang from files order by path")
             if lang not in NON_CODE and not (set(p.split("/")[:-1]) & IGNORE_DIRS) and not any(s.startswith(".") for s in p.split("/"))]
    for depth in (2, 1):
        key = {i: "/".join(p.split("/")[:-1][:depth]) or "." for i, p in files}
        if len(set(key.values())) <= MAX_UNITS or depth == 1:
            break
    u = {}
    for i, p in files:
        k = key[i]
        d = u.setdefault("dir:" + re.sub(r"[^A-Za-z0-9]+", "_", k).strip("_"), {"label": clip(k, 22) if k != "." else "root", "path": p, "role": "", "files": 0, "dir": k.rpartition("/")[0] if k != "." else ""})
        d["files"] += 1
    kid = {i: "dir:" + re.sub(r"[^A-Za-z0-9]+", "_", key[i]).strip("_") for i in key}
    e = sorted({(kid[a], kid[b]) for a, ds in g.adj.items() if a in kid for b in ds if b in kid and kid[a] != kid[b]})
    for d in u.values():
        d["role"] = f"{d['files']} source file{'s' if d['files'] != 1 else ''} in {d['label']}."
    return u, e


def _cap(u, e):
    if len(u) <= MAX_UNITS:
        return u, e, ""
    deg = defaultdict(int)
    for a, b in e:
        deg[a] += 1
        deg[b] += 1
    keep = set(sorted(u, key=lambda k: (-deg[k], k))[:MAX_UNITS])
    return ({k: v for k, v in u.items() if k in keep}, [x for x in e if x[0] in keep and x[1] in keep],
            f"{len(u) - MAX_UNITS} less connected modules are not drawn.")


def clip(s, limit):
    """Left-ellipsis: keeps the tail of a path so a long one never leaves its node."""
    return s if len(s) <= limit else "\u2026" + s[-(limit - 1):]


def sub(u):
    """Mono sub-label of a unit's node: its path, or the file count for a directory unit."""
    return f"{u['files']} files" if u.get("dir") is not None else clip(u["path"], 24)


def node_dict(bid, uid, u, fi, fo):
    return {"id": f"{bid}:{uid}", "name": u["label"], "sub": sub(u), "about": u["role"], "anchor": u["path"] + "#",
            "detail": f"{fi} module{'s' if fi != 1 else ''} depend on it; it depends on {fo}."}
