#!/usr/bin/env python3
"""One Haiku extraction for the three system views (context, containers, deployment), then the deterministic citation gate.

  extract_system.py <repo root>      prints the gated result (uses the cache; a changed input costs one call)

Input: README, top-level docs/*.md, manifests (depth <= 2) and the hook entries whose command points into the repo (nothing else of the
hook config is read or printed). Every line is numbered so the model can cite `path:line`.
Gate (0 tokens): the cited file is in the repo (or is the pseudo file `hook-config`), the line exists, and it contains the cited `term`,
case-folded. A node that fails is dropped. An edge that fails is kept dashed ("inferred") when both endpoints survive, else dropped.
Cache: ~/.cache/bree-architecture/system-<hash>.json holds the raw model output keyed by an input hash (repo path + prompt), so a
re-render, also in another output dir, costs 0 tokens. The gate is re-run on the cached raw output every time.
"""
import hashlib, json, os, re, shlex, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.expanduser("~/.cache/bree-architecture")
VERSION = "3"
MAX_CHARS = 6500           # prompt payload; about 2.5k tokens
KINDS = ("person", "external", "process", "cli", "hook", "daemon", "store", "file")
MANIFESTS = ("package.json", "pyproject.toml", "Package.swift", "Cargo.toml", "go.mod", "Makefile", "plugin.json", "Dockerfile")
HOOK = "hook-config"
SKIP = {".git", "node_modules", ".architecture", os.environ.get("BREE_INDEX_DIR", ".code-index"), "__pycache__", "venv", ".venv", "build", "dist"}


def read_lines(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return None


def points_into(cmd, root):
    root = os.path.realpath(root)
    try:
        toks = shlex.split(os.path.expandvars(cmd))
    except ValueError:
        return False
    for i, t in enumerate(toks):
        t = os.path.expanduser(t)
        p = t if os.path.isabs(t) else (shutil.which(t) if i == 0 else None)
        if p and os.path.realpath(p).startswith(root + os.sep):
            return True
    return False


def hook_lines(root, settings="~/.claude/settings.json"):
    """Only the entries whose command points into the repo; KEY=value tokens are stripped; no other value is read out."""
    try:
        d = json.load(open(os.path.expanduser(settings)))
    except (OSError, ValueError):
        return []
    out = []
    for ev, entries in sorted((d.get("hooks") or {}).items()):
        for e in entries if isinstance(entries, list) else []:
            for h in e.get("hooks", []):
                cmd = str(h.get("command", ""))
                if points_into(cmd, root):
                    cmd = " ".join(t for t in cmd.split() if not re.match(r"^\w+=", t))
                    out.append(f"{ev} {e.get('matcher', '')} :: {cmd}"[:200])
    return out


def sources(root, settings="~/.claude/settings.json"):
    """{rel path: [lines]} of the files the model may read, in a fixed order."""
    files = []
    for f in sorted(os.listdir(root)):
        if re.match(r"README", f, re.I) and os.path.isfile(os.path.join(root, f)):
            files.append(f)
    dd = os.path.join(root, "docs")
    if os.path.isdir(dd):
        files += ["docs/" + f for f in sorted(os.listdir(dd))[:8] if f.lower().endswith(".md") and os.path.isfile(os.path.join(dd, f))]
    for dp, dn, fn in os.walk(root):
        dn[:] = sorted(d for d in dn if d not in SKIP and not d.startswith("."))
        rel = os.path.relpath(dp, root)
        if rel != "." and rel.count(os.sep) >= 2:
            dn[:] = []
        for f in sorted(fn):
            if f in MANIFESTS or (f.lower().startswith("readme") and rel != "."):
                files.append(os.path.normpath(os.path.join(rel, f)))
    out = {}
    for f in files:
        L = read_lines(os.path.join(root, f))
        if L:
            out[f] = L
    h = hook_lines(root, settings)
    if h:
        out[HOOK] = h
    return out


def payload(src):
    parts, left = [], MAX_CHARS
    for p, L in src.items():
        take = 70 if p != HOOK else 20
        body = "\n".join(f"{i}: {t[:180]}" for i, t in enumerate(L[:take], 1) if t.strip())
        blk = f"### {p}\n{body}\n"
        if left <= 200:
            break
        parts.append(blk[:left])
        left -= len(blk)
    return "\n".join(parts)


PROMPT = """From the numbered files below, list the parts of this software system and how they connect. Use only what the text states.
Return one JSON object:
{{"nodes":[{{"id":"snake_case","name":"<=22 chars","kind":"person|external|process|cli|hook|daemon|store|file","host":"where it runs, <=18 chars (for example 'Claude Code hook', 'launchd', 'shell CLI', 'on disk'); persons and externals: ''","sub":"<=24 chars: the command or path","about":"1-2 plain sentences, <=140 chars, no code","cite":"path:line","term":"a word or phrase that appears verbatim on that line"}}],
"edges":[{{"from":"id of the INITIATOR (the one that acts, calls, fires, reads or writes)","to":"id of the RECEIVER (the one that is called, fired, read or written)","label":"<=14 chars","io":"read|write|spawn|call","cite":"path:line","term":"verbatim on that line"}}]}}
Rules: person = human user; external = a service or tool outside the repo; process/cli/hook/daemon = something that runs; store/file = data kept on disk. At most 12 nodes (at most 6 person/external) and 11 edges. Every node and edge needs a cite whose line really contains the term. Kinds: the developer, 'you' or the user is person; an agent session, subagent, host tool, other repo, model file or venv that is not part of the code here is external (never process or store). Context matters: list every actor and outside system the text names as person or external, for example the developer ('you', 'user'), the agent session or subagent that triggers or receives it, the repos it works on, the host tool whose config calls it, downloaded models or a venv. Give each its own cite. Edge direction is always initiator to receiver: the host that fires a hook is the initiator, the program that runs is the receiver. No invented parts. Answer with minified JSON on one line, nothing else. Repo: {repo}

{body}"""


def cite_ok(cite, term, root, src):
    """The deterministic gate: file in repo (or hook-config), line exists, line contains the term, case-folded."""
    try:
        path, ln = str(cite).rsplit(":", 1)
        ln = int(ln)
    except ValueError:
        return False
    term = str(term or "").strip().casefold()
    if len(term) < 3 or ln < 1:
        return False
    if path == HOOK:
        L = src.get(HOOK)
    else:
        full = os.path.realpath(os.path.join(root, path))
        if not full.startswith(os.path.realpath(root) + os.sep):
            return False
        L = src[path] if path in src and len(src[path]) >= ln else read_lines(full)
    return bool(L) and ln <= len(L) and term in L[ln - 1].casefold()


def clean(s, n):
    return " ".join(str(s or "").split())[:n]


def direction_ok(e, byid, root, src):
    """Where the cited line holds both endpoint terms, the initiator (from) must be named before the receiver (to); a reversed order makes
    the edge inferred (dashed). A line that names only one of them cannot say, so it passes."""
    try:
        path, ln = str(e["cite"]).rsplit(":", 1)
        line = (src.get(HOOK) if path == HOOK else read_lines(os.path.join(root, path)))[int(ln) - 1].casefold()
    except (KeyError, ValueError, TypeError, IndexError):
        return True
    a, b = byid[e["from"]]["term"], byid[e["to"]]["term"]
    ia, ib = line.find(a), line.find(b)
    return not (ia >= 0 and ib >= 0 and ia > ib)


def gate(raw, root, src):
    """raw model JSON -> {"nodes","edges","stats"}; counts feed Board.notes."""
    rn, re_ = (raw or {}).get("nodes") or [], (raw or {}).get("edges") or []
    nodes, seen = [], set()
    for x in rn:
        if not isinstance(x, dict):
            continue
        nid = re.sub(r"[^a-z0-9_]", "", str(x.get("id", "")).lower())
        if not nid or nid in seen or x.get("kind") not in KINDS or not clean(x.get("name"), 22):
            continue
        if not cite_ok(x.get("cite"), x.get("term"), root, src):
            continue
        about = clean(x.get("about"), 240)
        if "`" in about or len(str(x.get("about", ""))) > 240:
            about = ""
        seen.add(nid)
        nodes.append({"id": nid, "name": clean(x["name"], 22), "kind": x["kind"], "host": clean(x.get("host"), 18),
                      "sub": clean(x.get("sub"), 24), "about": about, "cite": str(x["cite"]), "term": str(x.get("term", "")).strip().casefold()})
    byid = {x["id"]: x for x in nodes}
    edges, dashed, dropped_e, es = [], 0, 0, set()
    for e in re_:
        if not isinstance(e, dict) or e.get("from") not in seen or e.get("to") not in seen or e["from"] == e["to"] or (e["from"], e["to"]) in es:
            dropped_e += 1
            continue
        ok = cite_ok(e.get("cite"), e.get("term"), root, src) and direction_ok(e, byid, root, src)
        dashed += (not ok)
        es.add((e["from"], e["to"]))
        edges.append({"from": e["from"], "to": e["to"], "label": clean(e.get("label"), 14), "io": e.get("io") if e.get("io") in ("read", "write", "spawn", "call") else "call", "inferred": not ok})
    stats = {"nodes_proposed": len(rn), "nodes_kept": len(nodes), "nodes_dropped": len(rn) - len(nodes),
             "edges_proposed": len(re_), "edges_kept": len(edges) - dashed, "edges_inferred": dashed, "edges_dropped": dropped_e}
    return {"nodes": nodes, "edges": edges, "stats": stats}


HOSTS = {".claude": "Claude Code"}   # settings dir -> the host tool that fires the hooks
INDEXES = re.compile(r"\bindex(?:es|ed|ing)?\b[^.\n]{0,40}?\b(?:repos?|repositor(?:y|ies)|codebases?)\b", re.I)


def seeds(root, src, settings):
    """Deterministic nodes and edges (0 tokens, independent of the model): the host tool whose hook config points into the repo and a Developer
    who uses it (the C4 default for a developer tool), cited to the hook entry; the repo the system indexes, cited to the README line that says so.
    Edges may end at the pseudo id "system" (the repo as one box); only the context view draws those."""
    nodes, edges = [], []
    hooks = src.get(HOOK)
    host = HOSTS.get(os.path.basename(os.path.dirname(os.path.expanduser(settings))))
    if hooks and host:
        cite, term = f"{HOOK}:1", hooks[0].split()[0].casefold()
        nodes.append({"id": "claude_code", "name": host, "kind": "external", "host": "", "sub": "host tool", "cite": cite, "term": term,
                      "about": f"{host} runs the hooks that call into this repo."})
        nodes.append({"id": "developer", "name": "Developer", "kind": "person", "host": "", "sub": "implied by hook config", "cite": cite, "term": term,
                      "about": f"The developer who works in {host} with this tool installed."})
        edges += [{"from": "developer", "to": "system", "label": "uses", "io": "call", "inferred": False},
                  {"from": "claude_code", "to": "system", "label": "fires hooks", "io": "call", "inferred": False}]
    for p, L in src.items():
        m = next(((i, INDEXES.search(t)) for i, t in enumerate(L, 1) if p != HOOK and INDEXES.search(t)), None)
        if m:
            nodes.append({"id": "indexed_repo", "name": "Indexed repo", "kind": "external", "host": "", "sub": "the repo it indexes", "cite": f"{p}:{m[0]}",
                          "term": m[1].group(0).casefold(), "about": "The repository the system indexes, as the cited line says."})
            edges.append({"from": "system", "to": "indexed_repo", "label": "indexes", "io": "read", "inferred": False})
            break
    return nodes, edges


def merge_seeds(g, sn, se):
    """Seeds first; a model node that is the same thing (same name, a host tool by name, any person for the Developer) folds into the seed and its edges follow."""
    if not sn:
        return g
    fold = {}
    for x in g["nodes"]:
        for s in sn:
            n, sname = x["name"].casefold(), s["name"].casefold()
            if n == sname or (s["id"] == "claude_code" and sname in n) or (s["id"] == "developer" and x["kind"] == "person") \
                    or (s["id"] == "indexed_repo" and x["kind"] == "external" and re.search(r"indexed|\brepo", n)):
                fold[x["id"]] = s["id"]
    nodes = sn + [x for x in g["nodes"] if x["id"] not in fold and x["id"] not in {s["id"] for s in sn}]
    seen = {(e["from"], e["to"]) for e in se}
    edges = list(se)
    for e in g["edges"]:
        a, b = fold.get(e["from"], e["from"]), fold.get(e["to"], e["to"])
        if a != b and (a, b) not in seen:
            seen.add((a, b))
            edges.append({**e, "from": a, "to": b})
    zero = {k: 0 for k in ("nodes_proposed", "nodes_kept", "nodes_dropped", "edges_proposed", "edges_kept", "edges_inferred", "edges_dropped")}
    st = {**zero, **g["stats"], "nodes_kept": g["stats"].get("nodes_kept", 0) + len(sn), "seeded": len(sn)}
    return {"nodes": nodes[:12], "edges": edges, "stats": st}


def extract(root, llm=None, budget=None, cache=CACHE, settings="~/.claude/settings.json"):
    """Gated result for a repo. Returns {"nodes","edges","stats","tokens","empty"}; tokens is what THIS call spent (0 when cached)."""
    root = os.path.abspath(root)
    src = sources(root, settings)
    sn, se = seeds(root, src, settings)
    if not any(p != HOOK for p in src):
        return {"nodes": [], "edges": [], "stats": {}, "tokens": 0, "empty": True}
    prompt = PROMPT.format(repo=os.path.basename(root), body=payload(src))
    key = hashlib.sha256((VERSION + root + prompt).encode()).hexdigest()[:16]
    cpath = os.path.join(cache, f"system-{key}.json")
    tokens = 0
    if os.path.exists(cpath):
        raw = json.load(open(cpath))["raw"]
    else:
        if llm is None:
            sys.path.insert(0, HERE)
            import gen
            llm = gen.llm
        raw, log = llm(prompt, "haiku", "system")
        tokens = log.get("tokens_in", 0) + log.get("tokens_out", 0)
        if budget is not None:
            budget.charge(tokens, "system-extract")
        if raw is None:
            g = merge_seeds({"nodes": [], "edges": [], "stats": {}}, sn, se)
            return {**g, "tokens": tokens, "empty": not g["nodes"]}
        os.makedirs(cache, exist_ok=True)
        json.dump({"raw": raw, "tokens": tokens, "log": log}, open(cpath, "w"), indent=1)
    g = merge_seeds(gate(raw, root, src), sn, se)
    return {**g, "tokens": tokens, "empty": not g["nodes"]}


if __name__ == "__main__":
    r = extract(sys.argv[1])
    print(json.dumps(r, indent=1))
