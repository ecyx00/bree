"""Shared helpers of the Runtime views (sequence, data-flow, state): flow loading, title fitting, storage access evidence."""
import os, re
from collections import defaultdict

STORE_TAG = {"Index": "DB", "Files": "FS", "Git": "GIT"}

# read / write evidence per storage kind, matched on the step body (plus tiny wrappers it calls); a write is only claimed when one of these matches
WRITE = {
    "Index": re.compile(r"\b(insert\s+(or\s+\w+\s+)?into|update\s+\w+\s+set|delete\s+from|replace\s+into|create\s+(virtual\s+)?(table|index)|drop\s+table)\b|executescript|executemany|\.commit\(", re.I),
    "Files": re.compile(r"""open\([^)]*["'][wax][bt+]*["']|mode\s*=\s*["'][wax]|\.write\(|write_text|write_bytes|os\.(remove|unlink|rename|replace|makedirs|utime)\b|shutil\.(copy\w*|move|rmtree)|\.unlink\(|\.mkdir\(|json\.dump\(|writeFile\w*\(|appendFile\w*\(|fs\.(rm|mkdir|rename|unlink)\w*\("""),
    "Git": re.compile(r"""["']git["']\s*,\s*["'](commit|add|checkout|reset|push|merge|stash|apply|rebase|rm|tag|init|clone|pull|fetch|restore|switch)["']|\bgit\s+(commit|add|checkout|reset|push|merge|stash|apply|rebase|rm|tag|init|clone|pull|fetch)\b"""),
}
READ = {
    "Index": re.compile(r"\bselect\b|\.fetch(all|one|many)\(|\bpragma\b", re.I),
    "Files": re.compile(r"""\bopen\(|read_text|read_bytes|os\.(stat|walk|scandir|listdir)|\bglob\(|getmtime|getsize|\.stat\(|json\.load\(|readFile\w*\(|readdir"""),
    "Git": re.compile(r"""["']git["']|\bgit\s+\w+"""),
}


# a file opened for write or append also matches READ["Files"] (`open(`): once a write is seen, only these count as a read
READ_AFTER_WRITE = re.compile(r"read_text|read_bytes|\.read\(|\.readlines?\(|json\.load\(|readFile\w*\(|getmtime|getsize|\.stat\(|os\.(walk|scandir|listdir)|\bglob\(|readdir")


def access_of(kind, text):
    """'READ' | 'WRITE' | 'READ/WRITE' | 'ACCESS' for a storage kind and the step body. ACCESS = the step touches the store but no read or write primitive is visible."""
    text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith(("#", "//")))
    w = bool(WRITE[kind].search(text)) if kind in WRITE else False
    r = bool(READ[kind].search(text)) if kind in READ else False
    if w and r and kind == "Git":
        r = False  # the git read pattern matches every git call, so a write call is not also a read
    return "READ/WRITE" if (w and r) else "WRITE" if w else "READ" if r else "ACCESS"


def graph_of(ctx):
    """The code-index graph of the repo (ctx.root is the real repo root)."""
    return ctx.graph


def step_text(ctx, s):
    """Body of a step's function, plus the bodies of the tiny (<= 8 lines) callees when the own body shows no primitive. '' when the graph is missing."""
    try:
        g = graph_of(ctx)
        path = s["sources"][0]["path"]
        sym = s["anchor"].rsplit(":", 1)[1].split("#")[0]
        sp = g.span(sym, path)
        if not sp:
            return ""
        txt = "\n".join(g.lines(path)[sp[0] - 1:sp[1]])
        out = txt
        for c in g.callees(sym, path):
            cs = g.span(c[0], c[1])
            if cs and cs[1] - cs[0] <= 8 and c[0] != sym:
                out += "\n" + "\n".join(g.lines(c[1])[cs[0] - 1:cs[1]])
        return out
    except Exception:
        return ""


def _sym_path(s):
    return s["anchor"].rsplit(":", 1)[1].split("#")[0], s["sources"][0]["path"]


def walk_evidence(ctx, steps, depth=8, cap=150):
    """Read / write evidence from the whole reachable call walk of a flow, not only the picked steps.
    Walks callees from the entry step (first visit wins, call-site order), reads each function's own body, and attaches what it finds to the
    nearest picked step on the path from the entry (the function itself when it is picked). -> {step id: [(kind, 'READ'|'WRITE', 'path:sym')]}"""
    out = {s["id"]: [] for s in steps}
    try:
        g = ctx.graph
        picked = {_sym_path(s): s["id"] for s in steps}
        seen, stack = set(), [(*_sym_path(s), None, 0) for s in reversed(steps)]   # entry pops first; a picked step the walk misses is still a root
        while stack and len(seen) < cap:
            sym, path, owner, d = stack.pop()
            if (sym, path) in seen:
                continue
            seen.add((sym, path))
            owner = picked.get((sym, path), owner)
            sp = g.span(sym, path)
            body = "\n".join(g.lines(path)[sp[0] - 1:sp[1]]) if sp else ""
            body = "\n".join(l for l in body.splitlines() if not l.lstrip().startswith(("#", "//")))
            if owner and body:
                for kind in ("Index", "Files", "Git"):
                    wrote = bool(WRITE[kind].search(body))
                    read = (READ_AFTER_WRITE if wrote and kind == "Files" else READ[kind]).search(body) and not (wrote and kind == "Git")
                    for how, hit in (("WRITE", wrote), ("READ", read)):
                        if hit:
                            out[owner].append((kind, how, f"{path}:{sym}"))
            if d < depth:
                for c in reversed(g.callees(sym, path)):   # reversed: the stack pops in call-site order
                    stack.append((c[0], c[1], owner, d + 1))
    except Exception:
        pass
    return out


def flows(doc):
    """[(board, steps by order, edges)] of every flow board that has steps."""
    steps_by, out = defaultdict(list), []
    for x in doc.get("nodes", []):
        if x["kind"] == "step":
            steps_by[x["board"]].append(x)
    for b in doc.get("boards", []):
        if b["kind"] == "overview" or not steps_by.get(b["id"]):
            continue
        st = sorted(steps_by[b["id"]], key=lambda s: s["order"])
        ids = {s["id"] for s in st}
        out.append((b, st, [e for e in doc["edges"] if e["board"] == b["id"] and e["from"] in ids and e["to"] in ids]))
    return out


def fit(title, prefix="", limit=12):
    """Board title of at most `limit` characters: prefix plus as many whole words of the flow title as fit (hard cut when the first word is too long)."""
    out = prefix
    for w in title.split():
        t = (out + " " + w).strip() if out else w
        if len(t) > limit:
            break
        out = t
    return out if len(out) > len(prefix) else (prefix + title)[:limit].rstrip()


def slug(board_id):
    return board_id[5:] if board_id.startswith("flow-") else board_id


def anchor_link(s):
    p, rest = s["anchor"].rsplit(":", 1)
    return p + "#" + rest.split("#")[0]
