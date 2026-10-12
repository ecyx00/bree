"""Runtime group: state machines read from status / enum fields by Haiku, then a deterministic cite gate (grammar after diagram-design type-state).
Every state and transition carries `cite: path:line`; the gate checks the file is inside the repo, the line exists and contains the cited term.
Anything that fails is dropped; a machine with fewer than 3 grounded states is dropped; no machine left means the empty state.
Cost: one Haiku call of at most ~6k tokens, cached by input hash in ~/.cache/bree-architecture (a re-render costs 0)."""
import hashlib, json, os, re, subprocess
from draw import Canvas, M, SMALL, esc, n, tw, up4, FW, FH, PITCH
from . import Board, empty_svg

BOARD_ID = "state"
STATE_BUDGET = 8000          # tokens this view may spend per generation
MAX_CHARS = 11000            # code shown to the model (about 3k tokens)
MAX_MACHINES, MAX_STATES = 3, 8
SRC_EXT = {".py", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".swift", ".go", ".rs", ".java", ".kt", ".rb", ".cs", ".php"}
SKIP = {"node_modules", ".git", os.environ.get("BREE_INDEX_DIR", ".code-index"), ".architecture", "tests", "test", "__tests__", "docs", "vendor", "dist", "build", "__pycache__", ".venv", "Pods"}
ENUM_RE = re.compile(r"^\s*(?:export\s+)?(?:const\s+)?(?:public\s+|private\s+|internal\s+)?(?:class\s+\w+\((?:str,\s*)?(?:Int|Str)?(?:Enum|Flag)\)|enum(?:\s+class)?\s+\w+|type\s+\w*(?:Status|State|Phase|Mode)\w*\s*=)")
LIT_RE = re.compile(r"""\b(status|state|phase)\w*\s*(?:[:=]|===?|!==?)\s*["'`][\w-]+["'`]""", re.I)


def files(root):
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, text=True, timeout=30).stdout.split("\0")
        out = [p for p in out if p]
    except Exception:
        out = []
    if not out:
        for d, ds, fs in os.walk(root, followlinks=True):
            ds[:] = sorted(x for x in ds if x not in SKIP)
            out += [os.path.relpath(os.path.join(d, f), root) for f in sorted(fs)]
    return sorted(p for p in out if os.path.splitext(p)[1] in SRC_EXT and not (set(p.split("/")[:-1]) & SKIP))


def snippets(root):
    """Deterministic candidate code: the files with the most enum / status-literal hits, as numbered lines `path:LINE| text`."""
    scored = []
    for p in files(root):
        try:
            if os.path.getsize(os.path.join(root, p)) > 300_000:
                continue
            lines = open(os.path.join(root, p), encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        hits = [(i, 3 if ENUM_RE.match(l) else 1) for i, l in enumerate(lines) if ENUM_RE.match(l) or LIT_RE.search(l)]
        if hits:
            scored.append((-sum(w for _, w in hits), p, lines, hits))
    out, used = [], 0
    for _, p, lines, hits in sorted(scored)[:6]:
        keep = set()
        for i, w in hits[:12]:
            keep.update(range(max(0, i - 1), min(len(lines), i + (11 if w == 3 else 2))))
        for i in sorted(keep)[:40]:
            row = f"{p}:{i + 1}| {lines[i].rstrip()[:150]}"
            if used + len(row) > MAX_CHARS:
                return "\n".join(out)
            out.append(row)
            used += len(row) + 1
    return "\n".join(out)


PROMPT = ("Below are numbered source lines (`path:LINE| code`). Find state machines: an enum, status or state field and the transitions between its values. "
          "Reply with one JSON object only: {\"machines\":[{\"name\":\"...\",\"about\":\"<= 12 words\",\"cite\":\"path:LINE\","
          "\"states\":[{\"name\":\"...\",\"cite\":\"path:LINE\"}],\"transitions\":[{\"from\":\"...\",\"to\":\"...\",\"event\":\"<= 3 words\",\"cite\":\"path:LINE\"}]}]}. "
          f"At most {MAX_MACHINES} machines and {MAX_STATES} states each. Use only the lines shown. A cite is the path:LINE of a shown line that contains that state value "
          "(for a transition: the line that assigns the target state or names the event). Do not invent states or transitions; omit what you cannot cite.\n\n")


def ask(prompt):
    import gen
    return gen.llm(prompt, "haiku", "state")


# ---------------------------------------------------------------- cite gate
def _norm(s):
    return re.sub(r"[^a-z0-9]", "", str(s).casefold())


def cited_line(root, cite, cache):
    """Text of the cited `path:line`, or None when the file is outside the repo, missing, or the line does not exist."""
    m = re.fullmatch(r"(.+):(\d+)", str(cite or "").strip())
    if not m:
        return None
    path = os.path.normpath(m.group(1))
    if os.path.isabs(path) or path.startswith(".."):
        return None
    if path not in cache:
        try:
            with open(os.path.join(root, path), encoding="utf-8", errors="replace") as f:
                cache[path] = f.read().splitlines()
        except OSError:
            cache[path] = None
    lines, ln = cache[path], int(m.group(2))
    return lines[ln - 1] if lines and 1 <= ln <= len(lines) else None


def gate(root, machines):
    """Keep only grounded states and transitions. Returns (machines, stats) with stats = {proposed, kept, dropped} over states and transitions."""
    cache, st = {}, {"proposed": 0, "kept": 0, "dropped": 0}
    kept = []
    for m in (machines if isinstance(machines, list) else [])[:MAX_MACHINES]:
        if not isinstance(m, dict):
            continue
        states, seen = [], set()
        for s in (m.get("states") or [])[:MAX_STATES]:
            st["proposed"] += 1
            nm = str(s.get("name", "")) if isinstance(s, dict) else ""
            t = cited_line(root, s.get("cite"), cache) if isinstance(s, dict) else None
            if nm and t is not None and _norm(nm) in _norm(t) and _norm(nm) not in seen:
                seen.add(_norm(nm))
                states.append({"name": nm, "cite": str(s["cite"]).strip()})
                st["kept"] += 1
            else:
                st["dropped"] += 1
        keys = {_norm(s["name"]): s["name"] for s in states}
        trans, tseen = [], set()
        for t in (m.get("transitions") or [])[:MAX_STATES * 3]:
            st["proposed"] += 1
            ok = False
            if isinstance(t, dict):
                a, b = keys.get(_norm(t.get("from", ""))), keys.get(_norm(t.get("to", "")))
                txt = cited_line(root, t.get("cite"), cache)
                ev = str(t.get("event", "") or "")
                if a and b and a != b and (a, b) not in tseen and txt is not None and (_norm(b) in _norm(txt) or (_norm(ev) and _norm(ev) in _norm(txt))):
                    tseen.add((a, b))
                    trans.append({"from": a, "to": b, "event": " ".join(ev.split())[:24], "cite": str(t["cite"]).strip()})
                    ok = True
            st["kept" if ok else "dropped"] += 1
        if len(states) >= 3:
            kept.append({"name": str(m.get("name", "state"))[:40], "about": " ".join(str(m.get("about", "")).split())[:100], "cite": states[0]["cite"],
                         "states": states, "transitions": trans})
    return kept, st


# ---------------------------------------------------------------- extraction + cache
def cache_file(root):
    d = os.environ.get("BREE_ARCH_CACHE_DIR") or os.path.expanduser("~/.cache/bree-architecture")
    return os.path.join(d, hashlib.sha1(os.path.abspath(root).encode()).hexdigest()[:12] + "-state.json")


def extract(ctx, root):
    """(proposed machines, tokens spent now, reason). Cached by the hash of the prompt: same code, same answer, 0 tokens."""
    code = snippets(root)
    if not code:
        return None, 0, "No status or enum fields found"
    prompt = PROMPT + code
    h = hashlib.sha1(prompt.encode()).hexdigest()
    cf = cache_file(root)
    try:
        c = json.load(open(cf))
        if c.get("input_hash") == h:
            return c["machines"], 0, ""
    except (OSError, ValueError, KeyError):
        pass
    est = len(prompt) // 4 + 1800
    if est > min(STATE_BUDGET, ctx.budget.left()):
        return None, 0, "State extraction skipped: token budget"
    out, log = ask(prompt)
    tokens = log.get("tokens_in", 0) + log.get("tokens_out", 0)
    if tokens:
        ctx.budget.charge(tokens, "state")
    if not isinstance(out, dict) or not isinstance(out.get("machines"), list):
        return None, tokens, "State extraction unavailable"
    os.makedirs(os.path.dirname(cf), exist_ok=True)
    json.dump({"input_hash": h, "machines": out["machines"], "tokens": tokens}, open(cf, "w"), indent=1)
    return out["machines"], tokens, ""


# ---------------------------------------------------------------- drawing
LEVEL, HEAD = 22, 56


def _order(m):
    names = [s["name"] for s in m["states"]]
    inc = {t["to"] for t in m["transitions"]}
    out, queue = [], [s for s in names if s not in inc][:1] or names[:1]
    while queue:
        s = queue.pop(0)
        if s in out:
            continue
        out.append(s)
        queue += [t["to"] for t in m["transitions"] if t["from"] == s and t["to"] not in out]
    return out + [s for s in names if s not in out]


def draw(machines, stats, tokens):
    cv = Canvas(BOARD_ID)
    nmax = max(len(m["states"]) for m in machines)
    W = up4(max(2 * M + nmax * PITCH - (PITCH - FW), 640))
    y, nodes = M, []
    for mi, m in enumerate(machines):
        order = _order(m)
        idx = {s: i for i, s in enumerate(order)}
        fwd = sorted((t for t in m["transitions"] if idx[t["to"]] > idx[t["from"]]), key=lambda t: (idx[t["to"]] - idx[t["from"]], idx[t["from"]]))
        bwd = sorted((t for t in m["transitions"] if idx[t["to"]] < idx[t["from"]]), key=lambda t: (idx[t["from"]] - idx[t["to"]], idx[t["from"]]))
        top_h, bot_h = (len(fwd) * LEVEL + 16 if fwd else 0), (len(bwd) * LEVEL + 16 if bwd else 0)
        cy = y + HEAD + top_h + FH / 2
        cx = {s: M + i * PITCH + FW / 2 for s, i in idx.items()}
        cv.back.append(f'<text class="eb" x="{M}" y="{n(y + 14)}" font-size="{SMALL}">{esc(m["name"].upper())}</text>'
                       f'<text class="lg" x="{M}" y="{n(y + 34)}" font-size="{SMALL}">{esc(m["about"] or m["cite"])}</text>')
        ports = {}
        for side, ts in (("t", fwd), ("b", bwd)):
            for t in ts:
                for end, other in (("from", "to"), ("to", "from")):
                    ports.setdefault((t[end], side), []).append((idx[t[other]], id(t), end))
        px = {}
        for (s, side), lst in ports.items():
            for k, (_, tid, end) in enumerate(sorted(lst)):
                px[(tid, end)] = cx[s] + (k - (len(lst) - 1) / 2) * 16
        for side, ts in (("t", fwd), ("b", bwd)):
            for k, t in enumerate(ts):
                lv = (y + HEAD + top_h - 12 - k * LEVEL) if side == "t" else (cy + FH / 2 + 14 + k * LEVEL)
                edge_y = cy - FH / 2 if side == "t" else cy + FH / 2
                xa, xb = px[(id(t), "from")], px[(id(t), "to")]
                a, b = f"{BOARD_ID}:m{mi}-{_slug(t['from'])}", f"{BOARD_ID}:m{mi}-{_slug(t['to'])}"
                cv.edge([(xa, edge_y), (xa, lv), (xb, lv), (xb, edge_y)], src=a, dst=b, title=t["cite"])
                if t["event"]:
                    cv.labels.append(f'<text class="lg" x="{n((xa + xb) / 2)}" y="{n(lv - 5)}" font-size="{SMALL}" text-anchor="middle">{esc(t["event"])}</text>')
        for s in m["states"]:
            nid = f"{BOARD_ID}:m{mi}-{_slug(s['name'])}"
            kind = "focal" if s["name"] == order[0] else "step"
            cv.flow_node(nid, cx[s["name"]], cy, FW, FH, s["name"], _short(s["cite"]), kind, False)
            nodes.append({"id": nid, "name": s["name"], "sub": _short(s["cite"]), "about": m["about"], "anchor": s["cite"].rsplit(":", 1)[0] + "#" + s["name"],
                          "detail": f"{m['name']}: state {s['name']}", "sources": [{"path": s["cite"].rsplit(":", 1)[0], "line": int(s["cite"].rsplit(":", 1)[1])}],
                          "lane": m["name"], "sym": s["name"]})
        y = cy + FH / 2 + bot_h + 36
    legend = [("focal", "Initial state"), ("box", "State"), ("line", "Transition (event)")]
    note = f"Cite gate: {stats['proposed']} proposed, {stats['kept']} kept, {stats['dropped']} dropped; every state shows its source file:line."
    lh = cv.legend(y, W, legend, note)
    H = up4(y + lh + M)
    svg = cv.svg(W, H, "State machines", f"{len(machines)} state machines with {sum(len(m['states']) for m in machines)} cited states.")
    return svg, nodes, legend, note


def _slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-") or "x"


def _short(cite):
    p, ln = cite.rsplit(":", 1)
    t = f"{os.path.basename(p)}:{ln}"
    return t if len(t) <= 20 else "…" + t[-19:]


def build(ctx):
    empty = lambda msg, tokens=0: Board(id=BOARD_ID, group="Runtime", title="State", purpose="State machines read from status and enum fields.",
                                       svg=empty_svg(msg), tokens=tokens)
    root = ctx.root
    if root is None:
        return empty("No repository to read")
    proposed, tokens, why = extract(ctx, root)
    if proposed is None:
        return empty(why, tokens)
    machines, stats = gate(root, proposed)
    if not machines:
        return empty(f"No state machine with 3 grounded states ({stats['proposed']} proposed, {stats['dropped']} dropped by the cite gate)", tokens)
    svg, nodes, legend, note = draw(machines, stats, tokens)
    return Board(id=BOARD_ID, group="Runtime", title="State", purpose=f"{len(machines)} state machine{'s' * (len(machines) > 1)}, every state and transition cited.",
                 svg=svg, nodes=nodes, legend=legend, notes=[note], tokens=tokens, entry=nodes[0]["id"])
