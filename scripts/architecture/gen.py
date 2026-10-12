#!/usr/bin/env python3
"""Per-module / per-workflow architecture diagram generator (v2: the graph gives the order, the LLM picks and names).

Flow = entry symbol -> call/ref walk (the index's `callees` + refs table, siblings by call-site line) -> LLM selects
and names steps from that tree (it cannot reorder or add) -> edges styled by evidence.
Writes <repo>/.architecture/current.architecture.json and a self-contained current.html.

  gen.py ROOT [--flow "name" | --flow "name::entry_symbol" ...] [--runs 3] [--model haiku]
              [--max-tokens 100000] [--out DIR] [--render-only] [--refresh "name"]
"""
import argparse, ast, datetime, json, os, re, shlex, shutil, sqlite3, statistics, subprocess, sys, tempfile, textwrap
from collections import defaultdict
from draw import humanize

HERE = os.path.dirname(os.path.abspath(__file__))
IGNORE_DIRS = {"bench", "benchmarks", "docs", "tests", "test", "examples", "node_modules", "__pycache__"}
DEFAULT_FLOWS = ["request-lifecycle", "data-flow", "pipeline"]
MAX_DEPTH, MAX_NODES = 2, 80
ENTRY_RE = re.compile(r"^(cmd_|main$|hook_|.*_cmd$|.*_hook$)")

SYSTEM = "You are a software architecture annotator. Reply with one JSON object only, no prose, no code fences. Never include source code."


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40] or "x"


# The code-graph CLI and its index directory; set BREE_INDEX_TOOL / BREE_INDEX_DIR to use your own.
INDEX_TOOL = os.environ.get("BREE_INDEX_TOOL", "code-index")
INDEX_DIR = os.environ.get("BREE_INDEX_DIR", ".code-index")


def hm(args, cwd):
    return subprocess.run([INDEX_TOOL, *args], cwd=cwd, capture_output=True, text=True).stdout


# ---------------------------------------------------------------- graph
class Graph:
    def __init__(self, root):
        self.root = root
        self.db = sqlite3.connect(f"file:{root}/{INDEX_DIR}/graph.db?mode=ro", uri=True)
        files = self.db.execute("select id,path,lang from files").fetchall()
        self.path_of = {i: p for i, p, _ in files}
        self.id_of = {p: i for i, p, _ in files}
        self.modules = {}
        for i, p, lang in files:
            if lang == "python" and not (set(p.split("/")[:-1]) & IGNORE_DIRS) and not p.endswith("__init__.py"):
                self.modules[re.sub(r"[^A-Za-z0-9]+", "_", p).strip("_")] = {"path": p, "fid": i}
        for n in sorted(os.listdir(root)):  # extensionless python launchers (not indexed)
            fp = os.path.join(root, n)
            if "." not in n and os.path.isfile(fp):
                try:
                    if b"python" in open(fp, "rb").readline():
                        self.modules[re.sub(r"\W+", "_", n)] = {"path": n, "fid": None}
                except OSError:
                    pass
        self.mod_of_path = {m["path"]: k for k, m in self.modules.items()}
        self.adj = defaultdict(set)
        for s, d in self.db.execute("select distinct src_file,dst_file from edges where src_file!=dst_file"):
            self.adj[s].add(d)
        self.top = defaultdict(list)  # name -> [(path, lo, hi)] top-level defs in modules
        for n, fid, lo, hi in self.db.execute("select name,file_id,lo,hi from symbols where (parent_id is null or parent_id=0)"):
            if self.path_of[fid] in self.mod_of_path:
                self.top[n].append((self.path_of[fid], lo, hi))
        self._src, self._callees = {}, {}

    def symbols(self, fid, cap=60):
        q = "select name from symbols where file_id=? and (parent_id is null or parent_id=0) order by lo limit ?"
        return [n for (n,) in self.db.execute(q, (fid, cap))]

    def module_edges(self):
        c = defaultdict(int)
        for s, ds in self.adj.items():
            ms = self.mod_of_path.get(self.path_of[s])
            for d in ds:
                md = self.mod_of_path.get(self.path_of[d])
                if ms and md and ms != md:
                    c[(ms, md)] += 1
        return dict(c)

    def lines(self, path):
        if path not in self._src:
            try:
                self._src[path] = open(os.path.join(self.root, path), encoding="utf-8", errors="replace").read().splitlines()
            except OSError:
                self._src[path] = []
        return self._src[path]

    def doc(self, path, lo):
        L = self.lines(path)
        for i in range(lo, min(lo + 6, len(L))):  # first docstring line right after the def
            s = L[i].strip()
            if s.startswith(('"""', "'''")):
                return s.strip("\"' ")[:90]
            if s and not s.startswith("#") and not s.endswith((":", "(", ",")):
                break
        if lo >= 2 and L[lo - 2].strip().startswith("#"):
            return L[lo - 2].strip("# ").strip()[:90]
        return ""

    def callees(self, sym, path):
        """[(name, path, def_line, call_line, via)] ordered by call-site line: index callees + names referenced inside the span."""
        key = (sym, path)
        if key in self._callees:
            return self._callees[key]
        blocks, cur = [], None
        for ln in hm(["callees", sym, "--limit", "200"], self.root).splitlines():
            h = re.match(r"^(\S+) \((\S+?):(\d+)-(\d+)\) calls", ln)
            if h:
                cur = {"path": h.group(2), "lo": int(h.group(3)), "hi": int(h.group(4)), "c": []}
                blocks.append(cur)
                continue
            m = re.match(r"^(\S+)\s+(\S+?):(\d+)\s+\(called at :(\d+)", ln)
            if m and cur is not None:
                cur["c"].append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4)), "call", 0))
        blk = next((b for b in blocks if b["path"] == path), None)
        out = [c for c in (blk["c"] if blk else []) if c[1] in self.mod_of_path]
        # indirect dispatch (dict values, lazy imports, argv branches) is a reference, not a call edge
        fid = self.id_of.get(path)
        span = next(((lo, hi) for p, lo, hi in self.top.get(sym, []) if p == path), None)
        if fid is not None and span:
            have = {c[0] for c in out} | {sym}
            for name, line in self.db.execute("select name,min(line) from refs where file_id=? and line between ? and ? group by name", (fid, *span)):
                defs = self.top.get(name, [])
                if name in have or not defs:
                    continue
                same = [d for d in defs if d[0] == path]
                pick = same[0] if same else (defs[0] if len(defs) == 1 else None)
                if pick:
                    out.append((name, pick[0], pick[1], line, "ref", 0))
                    have.add(name)
        out = [c[:5] + (self.col(path, c[3], c[0]),) for c in out]
        out.sort(key=lambda c: (c[3], c[5]))  # call-site (line, column), not the line alone
        self._callees[key] = out
        return out

    def col(self, path, line, name):
        L = self.lines(path)
        t = L[line - 1] if 0 < line <= len(L) else ""
        m = re.search(r"\b" + re.escape(name) + r"\s*\(", t) or re.search(r"\b" + re.escape(name) + r"\b", t)
        return m.start() if m else 0

    def sig(self, sym, path):
        """Parameter names of the def, or None (used to spot sibling handlers behind one dispatch)."""
        d = self.find(sym, path)
        if not d:
            return None
        L = self.lines(path)
        txt = " ".join(L[d[1] - 1:d[1] + 3]) if d[1] - 1 < len(L) else ""
        m = re.search(r"\bdef\s+\w+\s*\((.*?)\)\s*(?:->[^:]*)?:", txt) or re.search(r"\bfunction\s+\w+\s*\((.*?)\)", txt)
        return None if not m else tuple(p.split("=")[0].split(":")[0].strip() for p in m.group(1).split(",") if p.strip())

    def later_calls(self, sym, path, name, first):
        """Other call-site lines of `name` inside sym's body (the index reports only the first)."""
        span = next(((lo, hi) for p, lo, hi in self.top.get(sym, []) if p == path), None)
        if not span:
            return []
        rx = re.compile(r"\b" + re.escape(name) + r"\(")
        return [i for i in range(span[0], min(span[1], len(self.lines(path))) + 1) if i > first and rx.search(self.lines(path)[i - 1])]

    def key_of(self, sym, path, line):
        """Dispatch key written next to the handler on its call line, e.g. "event-name": handler."""
        L = self.lines(path)
        m = re.search(r"[\"']([^\"']+)[\"']\s*:\s*" + re.escape(sym) + r"\b", L[line - 1]) if 0 < line <= len(L) else None
        return m.group(1) if m else ""

    def filters(self, path, name, lines):
        """Is `name` called as a drop condition (`if not name(..)`, or `if name(..): ..; continue`) at any of its call lines?"""
        L = self.lines(path)
        rx = re.compile(r"\bif\s+not\s+" + re.escape(name) + r"\(|\bif\s+" + re.escape(name) + r"\([^#]*:\s*[^#]*\bcontinue\b")
        return any(0 < i <= len(L) and rx.search(L[i - 1]) for i in lines)

    def branches(self, sym, path):
        """Groups of sibling callees that are alternatives of one dispatch: same call line and identical (non-trivial) signature, 2+ members."""
        by = defaultdict(list)
        L = self.lines(path)
        for c in self.callees(sym, path):
            sg = self.sig(c[0], c[1])
            txt = L[c[3] - 1] if 0 < c[3] <= len(L) else ""
            # a handler is selected, not invoked, at its dispatch site (dict value, match arm, ref): `name` without `name(`
            if sg and (c[4] == "ref" or (re.search(r"\b" + re.escape(c[0]) + r"\b", txt) and not re.search(r"\b" + re.escape(c[0]) + r"\s*\(", txt))):
                by[(c[3], sg)].append(c)
        return [v for v in by.values() if len(v) >= 2]

    def span(self, sym, path):
        return next(((lo, hi) for p, lo, hi in self.top.get(sym, []) if p == path), None)

    def fn_ast(self, sym, path):
        """(ast of the def, first line number) for a python top-level def, or None."""
        sp = self.span(sym, path)
        if not sp or not path.endswith(".py"):
            return None
        try:
            return ast.parse(textwrap.dedent("\n".join(self.lines(path)[sp[0] - 1:sp[1]]))).body[0], sp[0] - 1
        except (SyntaxError, IndexError):
            return None

    def body_lines(self, sym, path, n=5, w=90):
        """First n code lines of the body: no blanks, comments or docstring."""
        sp = self.span(sym, path)
        if not sp:
            return []
        out, indoc = [], False
        for ln in self.lines(path)[sp[0]:sp[1]]:
            t = ln.strip()
            if indoc:
                indoc = '"""' not in t and "\'\'\'" not in t
                continue
            if not t or t.startswith("#"):
                continue
            if t.startswith(('"""', "\'\'\'")):
                indoc = not (len(t) > 3 and t.endswith(t[:3]))
                continue
            out.append(t[:w])
            if len(out) >= n:
                break
        return out

    def sig_line(self, sym, path):
        d = self.find(sym, path)
        L = self.lines(path)
        return L[d[1] - 1].strip()[:110] if d and d[1] - 1 < len(L) else ""

    def inlines(self, sym, path):
        """Steps with no function of their own, read from the body: a two-constant choice made by a % test (a bucket / arm), and the
        returned dict (what the caller gets)."""
        r = self.fn_ast(sym, path)
        if not r:
            return []
        fn, off = r
        out, rets = [], []
        for x in ast.walk(fn):
            if isinstance(x, ast.Assign) and isinstance(x.value, ast.IfExp) and isinstance(x.value.body, ast.Constant) \
                    and isinstance(x.value.orelse, ast.Constant) and any(isinstance(y, ast.BinOp) and isinstance(y.op, ast.Mod) for y in ast.walk(x.value.test)):
                out.append({"line": x.lineno + off, "col": x.col_offset, "kind": "choice"})
            if isinstance(x, ast.Return) and isinstance(x.value, ast.Dict):
                rets.append(x)
        if rets:
            x = max(rets, key=lambda y: y.lineno)
            out.append({"line": x.lineno + off, "col": x.col_offset, "kind": "output"})
        L = self.lines(path)
        for o in out:
            o["src"] = L[o["line"] - 1].strip()[:160]
        return out

    def groups(self, sym, path, cs):
        """Mutually exclusive callee groups from the if/elif/else arms of the body. -> [{line,end,cond,arms:[{cond,calls}],terminal}].
        A bare `if V:` / `if not V:` also puts the call that produced V (`V = f(..)` earlier) on the truthy side."""
        r = self.fn_ast(sym, path)
        if not r:
            return []
        fn, off = r
        assigns = defaultdict(list)
        for x in ast.walk(fn):
            if isinstance(x, ast.Assign) and isinstance(x.value, ast.Call):
                for t in x.targets:
                    for nm in ast.walk(t):
                        if isinstance(nm, ast.Name):
                            assigns[nm.id].append((x.lineno + off, x.value))
        by_line = defaultdict(list)
        for c in cs:
            by_line[c[3]].append(c)
        def calls_in(lo, hi):
            return [c for ln in range(lo, hi + 1) for c in by_line.get(ln, [])]
        found, claimed = [], set()
        for x in sorted((y for y in ast.walk(fn) if isinstance(y, ast.If)), key=lambda y: y.lineno):
            arms, cur = [], x
            while True:
                arms.append((ast.unparse(cur.test), cur.body, cur.test))
                if len(cur.orelse) == 1 and isinstance(cur.orelse[0], ast.If) and cur.orelse[0].lineno == cur.orelse[0].test.lineno:
                    cur = cur.orelse[0]
                    continue
                if cur.orelse:
                    arms.append(("otherwise", cur.orelse, None))
                break
            res = []
            for k, (cond, body, test) in enumerate(arms):
                lo, hi = body[0].lineno + off, max(getattr(b, "end_lineno", b.lineno) for b in body) + off
                mine = calls_in(lo, hi)
                if k == 0 and test is not None:
                    v = test.operand if isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not) else test
                    if isinstance(v, ast.Name) and assigns.get(v.id) and not isinstance(test, ast.UnaryOp):
                        prior = [a for a in assigns[v.id] if a[0] < x.lineno + off]
                        if prior:
                            nm = prior[-1][1].func.id if isinstance(prior[-1][1].func, ast.Name) else None
                            mine += [c for c in cs if c[0] == nm and c[3] == prior[-1][0]]
                res.append({"cond": cond, "calls": mine})
            full = [a for a in res if a["calls"]]
            ids = {c[:2] + (c[3],) for a in full for c in a["calls"]}
            end = x.end_lineno + off
            if len(full) >= 2 and not (ids & claimed):
                claimed |= ids
                prod = any(c[3] < x.lineno + off for a in full for c in a["calls"])
                found.append({"line": x.lineno + off, "end": end, "cond": res[0]["cond"], "arms": full,
                              "terminal": not prod and not any(c[3] > end for c in cs)})
        return found

    def storage(self, sym, path):
        """'Index' | 'Git' | 'Files' | None from the step's own body: db, git or filesystem primitives, directly or through a tiny
        repo wrapper (<= 8 lines) it calls (index callees)."""
        key = ("st", sym, path)
        if key in self._src:
            return self._src[key]
        def prim(sp, p):
            t = "\n".join(self.lines(p)[sp[0] - 1:sp[1]])
            if re.search(r"subprocess\.\w+\([^)]*[\"\']git[\"\']|\bgit\(|[\"\']git[\"\']\s*,", t):
                return "Git"
            if re.search(r"sqlite3|\.execute(?:many|script)?\(|\.cursor\(|\bexecutescript\(", t):
                return "Index"
            if re.search(r"\bopen\(|os\.(?:stat|walk|scandir|listdir|remove|unlink|rename|makedirs|utime)\b|shutil\.|\.(?:read_text|write_text|write_bytes|read_bytes|unlink)\(|\bglob\(|\.stat\(\)|getmtime|getsize", t):
                return "Files"
            return None
        sp = self.span(sym, path)
        out = prim(sp, path) if sp else None
        if not out and sp:
            for c in self.callees(sym, path):
                cs = self.span(c[0], c[1])
                if cs and cs[1] - cs[0] <= 8 and c[0] != sym:
                    out = prim(cs, c[1])
                    out = out if out in ("Index", "Git") else None  # a tiny wrapper only lends db / git access, not plain file checks
                    if out:
                        break
        self._src[key] = out
        return out

    def hook_args(self):
        """Argument tokens of every hook command in the agent settings that runs this tool (settings.json hooks, user and repo)."""
        if hasattr(self, "_ha"):
            return self._ha
        tool, args = os.path.basename(self.root), set()
        files = [os.path.expanduser("~/.claude/settings.json")] + [os.path.join(self.root, ".claude", n) for n in ("settings.json", "settings.local.json")]
        for f in files:
            try:
                hooks = json.load(open(f)).get("hooks") or {}
            except (OSError, ValueError, AttributeError):
                continue
            for ms in hooks.values():
                for m in ms if isinstance(ms, list) else []:
                    for h in m.get("hooks", []):
                        try:
                            tk = shlex.split(str(h.get("command", "")))
                        except ValueError:
                            continue
                        for i, t in enumerate(tk):
                            if os.path.basename(t) == tool:
                                args |= {a for a in tk[i + 1:] if not a.startswith("-")}
        self._ha = args
        return args

    def caller(self, sym):
        """'Claude Code agent' if a registration line for sym names a hook-config argument, 'User CLI' if it is a CLI subcommand
        registration, else None. Evidence only: lines that mention sym with a quoted subcommand/event string."""
        if hasattr(self, "_cl") and sym in self._cl:
            return self._cl[sym]
        if not hasattr(self, "_cl"):
            self._cl = {}
        ha, res = self.hook_args(), None
        rx = re.compile(r"\b" + re.escape(sym) + r"\b")
        for p in self.mod_of_path:
            if re.search(r"test", p):
                continue
            for ln in self.lines(p):
                if not rx.search(ln) or re.match(r"\s*(def|from|import)\b", ln):
                    continue
                q = set(re.findall(r"[\"\']([\w-]+)[\"\']", ln))
                if q & ha:
                    res = "Claude Code agent"
                elif res is None and (re.search(r"add_parser\(|set_defaults\(|@click\.|\.command\(", ln) or re.search(r"[\"\'][\w-]+[\"\']\s*,\s*" + re.escape(sym) + r"\b", ln)):
                    res = "User CLI"
                if res == "Claude Code agent":
                    break
            if res == "Claude Code agent":
                break
        self._cl[sym] = res
        return res

    def find(self, sym, path=None):
        d = [x for x in self.top.get(sym, []) if path in (None, x[0])]
        return d[0] if d else None

    def entry_candidates(self, cap=30):
        rx = [n for n in self.top if ENTRY_RE.match(n)]
        uncalled = [n for (n,) in self.db.execute(
            "select s.name from symbols s where (s.parent_id is null or s.parent_id=0) and s.kind like '%function%' "
            "and not exists(select 1 from refs r where r.name=s.name) order by s.file_id, s.lo")
            if n in self.top and n not in rx]
        out = []
        for n in rx + uncalled:
            p, lo, hi = self.top[n][0]
            n_c = len(self.callees(n, p)) if len(out) < cap else 0
            if len(out) < cap and n_c >= 1:
                out.append({"sym": n, "path": p, "line": lo, "doc": self.doc(p, lo), "callees": n_c})
        return out

    def walk(self, entry, path=None, choose=None):
        """Preorder tree from entry; children sorted by call-site (line, column), a filter by its LAST call site. Node: id, sym, path, line,
        call_line, via, parent, depth, doc, children[], kind (fn | choice | output), filters, also, site, fork {id, arm, cond, arm_cond}.
        Exclusive callee groups: a terminal group stays as a fork (tagged on its nodes); a non-terminal one is cut to one arm by `choose`."""
        d = self.find(entry, path)
        if not d:
            return []
        nodes, seen, nf = [], set(), [0]
        def add(sym, path, line, call_line, via, parent, depth, **kw):
            n = {"id": len(nodes) + 1, "sym": sym, "path": path, "line": line, "call_line": call_line, "via": via, "parent": parent,
                 "depth": depth, "doc": self.doc(path, line) if kw.get("kind", "fn") == "fn" else "", "children": [], "kind": "fn",
                 "filters": False, "also": [], "site": call_line, "fork": None, **kw}
            nodes.append(n)
            seen.add((sym, path))
            if parent:
                nodes[parent - 1]["children"].append(n["id"])
            if n["kind"] != "fn" or depth >= MAX_DEPTH:
                return
            cs = self.callees(sym, path)
            for grp in self.branches(sym, path):  # same-line dispatcher: one handler, the rest cut before selection
                keep = choose((sym, path), [[c] for c in grp], "handler") if choose else 0
                cs = [c for c in cs if c not in grp or c == grp[keep]]
            forkof = {}
            for g in self.groups(sym, path, cs):
                if g["terminal"]:
                    nf[0] += 1
                    for k, arm in enumerate(g["arms"]):
                        for c in arm["calls"]:
                            forkof[c[:2] + (c[3],)] = {"id": f"F{nf[0]}", "arm": k, "cond": g["cond"], "arm_cond": arm["cond"], "line": g["line"], "narms": len(g["arms"])}
                elif choose:
                    k = choose((sym, path), [a["calls"] for a in g["arms"]], "arm", [a["cond"] for a in g["arms"]])
                    drop = {c for j, a in enumerate(g["arms"]) if j != k for c in a["calls"]}
                    cs = [c for c in cs if c not in drop]
            items = []
            for c in cs:
                also = self.later_calls(sym, path, c[0], c[3])
                filt = depth <= 1 and self.filters(path, c[0], [c[3]] + also)
                site = also[-1] if filt and also else c[3]
                key = (site, self.col(path, site, c[0])) if filt and also else (c[3], c[5])
                items.append((key, "fn", c, also, filt, site))
            if depth <= 1:
                for o in self.inlines(sym, path):
                    items.append(((o["line"], o["col"]), o["kind"], o, [], False, o["line"]))
            for key, kind, c, also, filt, site in sorted(items, key=lambda i: i[0]):
                if kind != "fn":
                    add(f"{sym}#{c['line']}", path, c["line"], c["line"], "inline", n["id"], depth + 1, kind=kind, src=c["src"])
                elif (c[0], c[1]) not in seen and len(nodes) < MAX_NODES:
                    add(c[0], c[1], c[2], c[3], c[4], n["id"], depth + 1, filters=filt, also=also, site=site, fork=forkof.get(c[:2] + (c[3],)))
        add(entry, d[0], d[1], 0, "entry", 0, 0)
        return nodes


# ---------------------------------------------------------------- LLM
def llm(prompt, model, tag):
    with tempfile.TemporaryDirectory() as cwd:
        r = subprocess.run(
            ["claude", "-p", "--model", model, "--output-format", "json", "--tools", "",
             "--system-prompt", SYSTEM, "--setting-sources", "", "--disable-slash-commands",
             "--strict-mcp-config", "--no-session-persistence"],
            input=prompt, capture_output=True, text=True, cwd=cwd, timeout=300)
    log = {"board": tag, "model": model, "ok": False}
    try:
        j = json.loads(r.stdout)
    except ValueError:
        log["error"] = (r.stderr or r.stdout)[:200]
        return None, log
    u = j.get("usage", {})
    log.update(tokens_in=u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0),
               tokens_out=u.get("output_tokens", 0), cost_usd=round(j.get("total_cost_usd", 0), 5))
    m = re.search(r"\{.*\}", j.get("result", ""), re.S)
    try:
        out = json.loads(m.group(0)) if m else None
        log["ok"] = out is not None
    except ValueError:
        out = None
    return out, log


def used(logs):
    return sum(l.get("tokens_in", 0) + l.get("tokens_out", 0) for l in logs)


def readme_ownership(root):
    try:
        t = open(os.path.join(root, "README.md"), encoding="utf-8").read()
    except OSError:
        return ""
    m = re.search(r"^## Module ownership\n(.*?)(?=^## |\Z)", t, re.S | re.M)
    return m.group(1).strip()[:4000] if m else ""


def overview_prompt(g):
    lines = [f"- {k} ({m['path']}): " + ", ".join(g.symbols(m["fid"], 10)) if m["fid"] else f"- {k} ({m['path']}): launcher script, no indexed symbols"
             for k, m in g.modules.items()]
    own = readme_ownership(g.root)
    return ("Name each module of this repo. Modules are fixed (from a code index); do not add or remove any.\n"
            + (f"The README section below is ground truth for what each module owns. Use it for the roles.\n--- README Module ownership ---\n{own}\n---\n" if own else "")
            + "Modules (id, path, some top-level symbols):\n" + "\n".join(lines) +
            '\n\nReturn {"modules":{"<id>":{"label":"2-3 word name","role":"max 10 words, what it owns"}}} for every id. A launcher stub is a launcher, not a package root.')


def entry_prompt(flow, cands):
    lines = [f"{i}. {c['sym']} ({c['path']}:{c['line']}, {c['callees']} callees) {c['doc']}" for i, c in enumerate(cands, 1)]
    return (f'Workflow to diagram: "{flow}".\nPick the ONE entry point where this workflow starts, from this list of candidates '
            "(hook handlers, CLI commands, main functions). Prefer the outermost function the runtime calls first.\n" + "\n".join(lines) +
            '\n\nReturn {"entry":<candidate number>}.')


ACTORS = ("Claude Code agent", "User CLI", "tool", "Index", "Files", "Git")
DROP_RE = re.compile(r"\b(drop|skip|filter|remov|exclud|omit|ignor|discard|reject)", re.I)
KIND_DESC = {"choice": "assigns one of two constants from a modulo test (a bucket)", "output": "returns the result dict to the caller"}


def branch_prompt(flow, parent, options, conds, g):  # options: list of call lists (one per alternative)
    lines = []
    for i, calls in enumerate(options, 1):
        c = calls[0]
        k = g.key_of(c[0], parent[1], c[3])
        lines.append(f"{i}. " + (f"when `{conds[i-1]}`: " if conds else "") + ", ".join(x[0] for x in calls) + f" ({c[1]}:{c[2]})"
                     + (f' dispatch key "{k}"' if k else "") + f" {g.doc(c[1], c[2])}")
    return (f'Workflow to diagram: "{flow}".\n`{parent[0]}` runs exactly one of these alternatives, depending on the event or condition. '
            "Pick the ONE alternative this workflow runs; match the flow name against the dispatch key, condition and names as whole words (a longer word that merely contains the flow's word is a different alternative).\n"
            + "\n".join(lines) + '\n\nReturn {"branch":<number>}.')


def tree_text(g, nodes):
    out = []
    for n in nodes:
        ind = "  " * n["depth"]
        if n["kind"] != "fn":
            p = nodes[n["parent"] - 1]
            out.append(f"{ind}{n['id']}. [inline in {p['sym']}, :{n['line']}] {KIND_DESC[n['kind']]}: `{n['src']}`")
            continue
        tags = "" if n["via"] == "entry" else f" [{n['via']} at :{n['site']}]"
        if n["filters"]:
            tags += " [filter: called as a condition that drops items]"
        if n["also"]:
            tags += f" [also called at :{', :'.join(map(str, n['also']))}]"
        f = n["fork"]
        if f:
            tags += f" [fork {f['id']}, alternative {f['arm'] + 1} of {f['narms']}: when `{f['arm_cond']}`]"
        out.append(f"{ind}{n['id']}. {n['sym']} ({n['path']}:{n['line']}){tags}")
        if n["depth"] <= 2:  # full context near the entry; deeper nodes are details of their parent
            det = [g.sig_line(n["sym"], n["path"]), n["doc"] and "doc: " + n["doc"]]
            if n["parent"]:
                pn = nodes[n["parent"] - 1]
                L = g.lines(pn["path"])
                det.append("called in: `" + (L[n["site"] - 1].strip()[:120] if 0 < n["site"] <= len(L) else "") + "`")
            det += g.body_lines(n["sym"], n["path"], 5 if n["depth"] <= 1 else 3, 80)
            out += [f"{ind}   {x}" for x in det if x]
        elif n["doc"]:
            out.append(f"{ind}   doc: {n['doc']}")
    return "\n".join(out)


def select_prompt(g, flow, nodes, hook):
    return (f'Workflow to diagram: "{flow}".\nBelow is the call tree walked from the entry point, in call order, with each node\'s signature, doc, '
            "the line that calls it and the first lines of its body. Always include node 1 (the entry). Then choose the other 5 to 9 nodes that matter: "
            "the main stages in order, the nodes that do the work of each stage. Fold a sub-step into its parent's label. You may skip nodes; you may NOT reorder or use a node that is not in the tree.\n"
            "Skip helpers that only log, time, format output, compute paths or open handles, unless the workflow is about them. Keep steps that change what the user finally gets: "
            "filters (nodes tagged [filter]), a test-group or A/B arm assignment, and the node that puts the result into the output. Details inside a step belong to that step, not to a step of their own.\n"
            "Labels say what the step DOES to the data or the result, in the verb of the code, not how it fails. Read the 'called in' line: if the node is used as a condition that drops items "
            "(tag [filter]) the label must say it drops, skips or filters them, never that it keeps them. A step that only checks must say check.\n"
            + ("The entry is run by an outside caller: keep the node that hands the result back to that caller as the last step.\n" if hook else "")
            + "Nodes tagged [fork Fn, alternative k of m] are mutually exclusive alternatives (only one runs). If the workflow name selects one alternative, pick steps only from it. "
            "Otherwise pick steps from both and name the fork.\n"
            + tree_text(g, nodes) +
            '\n\nReturn {"steps":[{"id":<node number>,"label":"max 8 words, no code"}],"forks":[{"fork":"F1","question":"max 6 words, the decision","arms":["max 3 words","max 3 words"]}]} '
            "with steps in tree order; forks only for forks you picked steps from (else []).")


def fix_prompt(n, nodes, g, label):
    L = g.lines(nodes[n["parent"] - 1]["path"])
    return (f'This step is used as a condition that DROPS items from what the user finally gets.\nName: {n["sym"]}  {n["doc"]}\n'
            f'Called in: `{L[n["site"] - 1].strip()[:140]}`\nBody: ' + " ; ".join(g.body_lines(n["sym"], n["path"], 6, 80)) +
            f'\nCurrent label: "{label}". Rewrite it so it says what is dropped, starting with Drop, Skip or Filter. Max 8 words, no code.\nReturn {{"label":"..."}}.')


# ---------------------------------------------------------------- flow
def first_sentence(doc, sym):
    t = re.split(r"(?<=[.;:])\s", doc.strip(), 1)[0].strip(" .:;")[:60] if doc else ""
    return t or sym.split("#")[0].replace("_", " ")


FALLBACK = {"choice": "Pick a test group by a bucket test", "output": "Return the result to the caller"}


def step_pairs(steps, nodes, g):
    """Edges: solid for call/ref/order evidence, dashed for inferred; a fork gets decision -> each arm and arm ends -> the next common step."""
    pairs = []
    def evidence(a, b):
        na, nb = nodes[a["node"] - 1], nodes[b["node"] - 1]
        direct = next((c for c in g.callees(na["sym"], na["path"]) if c[0] == nb["sym"] and c[1] == nb["path"]), None) if na["kind"] == "fn" else None
        if direct:
            return "ref" if direct[4] == "ref" else "call"
        if na["parent"] and na["parent"] == nb["parent"] and na["call_line"] <= nb["call_line"]:
            return "order"
        return "inferred"
    def add(a, b, via=None, label=None):
        via = via or evidence(a, b)
        p = {"from": a["anchor"], "to": b["anchor"], "via": via, "solid": via != "inferred"}
        if label:
            p["label"] = label
        pairs.append(p)
    for i in range(1, len(steps)):
        prev, cur = steps[i - 1], steps[i]
        if cur.get("decision"):
            add(prev, cur, "order")
        elif cur.get("arm") is not None:
            same = prev.get("fork") == cur["fork"]
            dec = next(x for x in steps if x.get("decision") and x["fork"] == cur["fork"])
            if same and prev.get("arm") == cur["arm"]:
                add(prev, cur)
            else:
                add(dec, cur, "branch", dec["decision"]["arms"][cur["arm"]])
        elif prev.get("arm") is not None:  # the common step after a fork: every arm end flows into it
            f = prev["fork"]
            ends = {}
            for x in steps[:i]:
                if x.get("fork") == f and x.get("arm") is not None:
                    ends[x["arm"]] = x
            for x in ends.values():
                add(x, cur, "order")
        else:
            add(prev, cur)
    return pairs


def build_run(g, flow, entry, cands, memo, logs, model, cap):
    """One LLM run (the selection call) -> dict(entry, entry_by, steps, dropped, reordered, pairs, stats, forks)."""
    by = "user" if entry else "llm"
    if not entry:
        out, log = llm(entry_prompt(flow, cands), model, "entry:" + slug(flow))
        logs.append(log)
        e = (out or {}).get("entry") if isinstance(out, dict) else None
        try:
            c = cands[int(e) - 1]
        except (TypeError, ValueError, IndexError):
            print(f"[{flow}] entry {e!r} not a candidate number", file=sys.stderr)
            return None
        entry, path = c["sym"], c["path"]
    else:
        path = None
    def choose(parent, options, kind, conds=None):
        k = (parent, tuple(tuple(c[0] for c in o) for o in options))
        if k not in memo:  # one answer per flow, shared by all runs (the flow name decides, not the run)
            o, lg = llm(branch_prompt(flow, parent, options, conds, g), model, "branch:" + slug(flow))
            logs.append(lg)
            try:
                memo[k] = int((o or {}).get("branch")) - 1
                options[memo[k]]
            except (TypeError, ValueError, IndexError):
                memo[k] = 0
        if kind == "handler":
            memo.setdefault("forced", set()).add(options[memo[k]][0][:2])
        return memo[k]
    nodes = g.walk(entry, path, choose)
    if not nodes or used(logs) >= cap:
        return None
    caller = g.caller(nodes[0]["sym"])
    out, log = llm(select_prompt(g, flow, nodes, caller == "Claude Code agent"), model, "flow:" + slug(flow))
    logs.append(log)
    raw = (out or {}).get("steps", []) if isinstance(out, dict) else []
    picked, dropped, seen = {}, [], set()
    for s in raw:
        try:
            i = int(s["id"]) if isinstance(s, dict) else None
        except (KeyError, ValueError, TypeError):
            i = None
        if i is None or not 1 <= i <= len(nodes):
            dropped.append(str(s)[:80])  # not in the tree: dropped and logged
        elif i not in seen:
            seen.add(i)
            picked[i] = str(s.get("label", "")).strip()[:80]
    for i, x in enumerate(nodes, 1):  # a chosen dispatch handler is a stage of the flow by definition
        if x["kind"] == "fn" and (x["sym"], x["path"]) in memo.get("forced", ()) and i not in seen:
            seen.add(i)
            picked[i] = ""
    picked.setdefault(1, "")
    if caller == "Claude Code agent" and not any(nodes[i - 1]["kind"] == "output" for i in picked):  # a hook's last step is its return to the caller
        outs = [x["id"] for x in nodes if x["kind"] == "output" and x["parent"] in picked]
        if outs:
            picked[outs[-1]] = ""
    reordered = [i for i, _ in picked.items()] != sorted(picked)
    ids = sorted(picked)
    # 0-token lint: a step called as a filter must say it drops/skips/filters; one re-ask for that step only
    lint = []
    for i in ids:
        n = nodes[i - 1]
        if n["filters"] and not DROP_RE.search(picked[i]):
            o, lg = llm(fix_prompt(n, nodes, g, picked[i]), model, "lint:" + slug(flow))
            logs.append(lg)
            new = str((o or {}).get("label", "")).strip()[:80] if isinstance(o, dict) else ""
            lint.append({"step": n["sym"], "was": picked[i], "now": new, "fixed": bool(DROP_RE.search(new))})
            if DROP_RE.search(new):
                picked[i] = new
    fk = {f.get("fork"): f for f in (out or {}).get("forks", []) if isinstance(f, dict)} if isinstance(out, dict) else {}
    steps = []
    for i in ids:
        n = nodes[i - 1]
        lab = picked[i] or (FALLBACK.get(n["kind"]) or first_sentence(n["doc"], n["sym"]))
        if n["kind"] == "fn" and n["via"] == "entry" or n["kind"] == "output":
            act = caller if caller and (n["via"] == "entry" or caller == "Claude Code agent") else None
        else:
            act = None
        act = act or ("tool" if n["kind"] != "fn" else (g.storage(n["sym"], n["path"]) or "tool"))
        st = {"anchor": f"{n['path']}:{n['sym']}", "label": lab, "path": n["path"], "line": n["line"], "module": g.mod_of_path[n["path"]],
              "node": i, "via": n["via"], "order": 0, "actor": act, "arm": None, "fork": None}
        if n["kind"] != "fn":
            st["src"] = n["src"]
        if n["fork"]:
            st["fork"], st["arm"] = n["fork"]["id"], n["fork"]["arm"]
        steps.append(st)
    # forks with steps in 2+ arms become a decision step before the first arm step; otherwise the fork tag is dropped
    out_steps, done = [], set()
    for st in steps:
        f = st["fork"]
        if f and f not in done:
            arms = {x["arm"] for x in steps if x["fork"] == f}
            n = nodes[st["node"] - 1]
            if len(arms) < 2:
                for x in steps:
                    if x["fork"] == f:
                        x["fork"] = x["arm"] = None
            else:
                done.add(f)
                meta = n["fork"]
                par = nodes[n["parent"] - 1]
                q = str((fk.get(f) or {}).get("question") or "").strip()[:60]
                al = (fk.get(f) or {}).get("arms") or []
                labs = [str(al[k])[:30] if k < len(al) and str(al[k]).strip() else (meta["arm_cond"] if k == 0 else "otherwise") for k in range(meta["narms"])]
                out_steps.append({"anchor": f"{par['path']}:{par['sym']}#fork{meta['line']}", "label": q or f"Is it {meta['cond']}?"[:60], "path": par["path"],
                                  "line": meta["line"], "module": g.mod_of_path[par["path"]], "node": par["id"], "via": "fork", "order": 0, "actor": "tool",
                                  "arm": None, "fork": f, "decision": {"arms": labs}})
        out_steps.append(st)
    steps = out_steps
    for k, st in enumerate(steps, 1):
        st["order"] = k
    pairs = step_pairs(steps, nodes, g)
    log.update(steps_picked=len(steps), dropped=len(dropped), reordered=reordered, lint=lint)
    return {"entry": entry, "entry_by": by, "steps": steps, "dropped": dropped, "reordered": reordered, "pairs": pairs, "caller": caller, "lint": lint,
            "stats": {"pairs": len(pairs), "pairs_solid": sum(p["solid"] for p in pairs), "tree_nodes": len(nodes)}}


def build_flow(g, flow, entry, runs, model, logs, cap, cands):
    res, memo = [], {}
    for _ in range(runs):
        if used(logs) >= cap:
            print("token cap reached, skipping", flow, file=sys.stderr)
            break
        r = build_run(g, flow, entry, cands, memo, logs, model, cap)
        if r:
            res.append(r)
    return res


def board_flow(name, res, model, cands):
    r = res[0]
    ratios = [x["stats"]["pairs_solid"] / max(x["stats"]["pairs"], 1) for x in res]
    return {"id": "flow-" + slug(name), "title": name, "kind": "flow", "model": model,
            "entry": {"symbol": r["entry"], "chosen_by": r["entry_by"], "caller": r["caller"], "candidates": [c["sym"] for c in cands]},
            "stats": {**r["stats"], "solid_median": statistics.median(ratios), "solid_range": [min(ratios), max(ratios)], "runs": len(res)},
            "steps": r["steps"], "pairs": r["pairs"], "dropped": r["dropped"],
            "runs": [{"entry": x["entry"], "steps": [s["anchor"] for s in x["steps"]], "labels": {s["anchor"]: s["label"] for s in x["steps"]},
                      "srcs": {s["anchor"]: s["src"] for s in x["steps"] if s.get("src")}, "lint": x["lint"],
                      "dropped": x["dropped"], "reordered": x["reordered"], "pairs": x["stats"]["pairs"], "pairs_solid": x["stats"]["pairs_solid"]} for x in res]}


# ---------------------------------------------------------------- overview edges
def overview_edges(g):
    """All edges kept in JSON with a `hidden` reason; the board draws only the visible ones."""
    raw = g.module_edges()
    n = len(g.modules)
    indeg = defaultdict(int)
    for (a, b) in raw:
        indeg[b] += 1
    hubs = {k for k, v in indeg.items() if v >= 0.6 * n}
    hidden = {}
    for (a, b) in raw:
        if a in hubs or b in hubs:
            hidden[(a, b)] = "hub"
    for (a, b), w in raw.items():  # strongest direction per module pair
        r = raw.get((b, a))
        if r is not None and (a, b) not in hidden and (b, a) not in hidden and (r, b, a) > (w, a, b):
            hidden[(a, b)] = "weaker-direction"
    keep = {e: w for e, w in raw.items() if e not in hidden}
    succ = defaultdict(set)
    for (a, b) in keep:
        succ[a].add(b)
    def reach(a, skip):  # is b reachable from a without the direct edge
        stack, seen = [x for x in succ[a] if x != skip[1]], set()
        while stack:
            x = stack.pop()
            if x == skip[1]:
                return True
            if x not in seen:
                seen.add(x)
                stack.extend(succ[x])
        return False
    for e in sorted(keep, key=lambda e: keep[e]):  # weakest first
        if reach(e[0], e):
            hidden[e] = "implied"
            succ[e[0]].discard(e[1])
    return raw, hidden, hubs


# ---------------------------------------------------------------- document
def make_doc(g, roles, boards, runs, commit):
    nodes, edges = [], []
    for k, m in g.modules.items():
        nodes.append({"id": "mod:" + k, "label": roles.get(k, {}).get("label") or humanize(m["path"]), "board": "overview", "kind": "module",
                      "role": roles.get(k, {}).get("role", ""), "sources": [{"path": m["path"], "line": 1}]})
    raw, hidden, hubs = overview_edges(g)
    for (a, b), n in raw.items():
        edges.append({"id": f"overview:mod:{a}->mod:{b}", "from": "mod:" + a, "to": "mod:" + b, "board": "overview", "solid": True, "weight": n,
                      **({"hidden": hidden[(a, b)]} if (a, b) in hidden else {})})
    for b in boards:
        sid = lambda s: f"{b['id']}:{slug(s['anchor'])}"
        seen = set()
        for s in b["steps"]:
            if sid(s) in seen:
                continue
            seen.add(sid(s))
            nodes.append({"id": sid(s), "label": s["label"], "board": b["id"], "kind": "step", "module": "mod:" + s["module"],
                          "order": s["order"], "actor": s.get("actor", "tool"), "anchor": s["anchor"],
                          **({"decision": s["decision"]} if s.get("decision") else {}), "sources": [{"path": s["path"], "line": s["line"], "label": s["anchor"]}]})
        by = {s["anchor"]: s for s in b["steps"]}
        for p in b["pairs"]:
            f, t = sid(by[p["from"]]), sid(by[p["to"]])
            edges.append({"id": f"{b['id']}:{f}->{t}", "from": f, "to": t, "board": b["id"], "solid": p["solid"], "via": p["via"],
                          **({"label": p["label"]} if p.get("label") else {})})
    tin = sum(l.get("tokens_in", 0) for r in runs for l in r["calls"])
    tout = sum(l.get("tokens_out", 0) for r in runs for l in r["calls"])
    return {"schema": "bree-architecture/2", "repo": os.path.basename(g.root), "commit": commit,
            "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "boards": [{"id": "overview", "title": "Modules", "kind": "overview"}] +
                      [{k: v for k, v in b.items() if k in ("id", "title", "kind", "model", "entry", "stats")} for b in boards],
            "nodes": nodes, "edges": edges, "flows": boards, "roles": roles,
            "overview_hidden": {"hubs": sorted(hubs), "counts": {r: sum(1 for v in hidden.values() if v == r) for r in set(hidden.values())}},
            "generation": {"runs": runs, "totals": {"tokens_in": tin, "tokens_out": tout,
                           "cost_usd": round(sum(l.get("cost_usd", 0) for r in runs for l in r["calls"]), 5)}}}


def write_html(doc, path, root=None):
    import render, views
    npath = os.path.join(os.path.dirname(path), "names.json")  # sidecar written by names.py; absent -> first words of the label
    side = json.load(open(npath)) if os.path.exists(npath) else {}
    root = root or os.path.dirname(os.path.dirname(os.path.abspath(path)))  # default <root>/.architecture/current.html; an explicit --out elsewhere passes root
    budget = views.TokenBudget()
    page = render.render_page(doc, side.get("names", {}), side.get("about", {}), root=root, budget=budget, arch_dir=os.path.dirname(path))
    if budget.log:  # views that called an LLM record it in the generation JSON; with none, the JSON stays untouched
        doc["generation"]["views"] = {"cap": budget.cap, "used": budget.used, "calls": budget.log}
        json.dump(doc, open(os.path.join(os.path.dirname(path), "current.architecture.json"), "w"), indent=1)
    open(path, "w", encoding="utf-8").write(page)


def keep_prev(jpath):
    """A full or refresh run is about to overwrite the JSON: keep the old one as current.architecture.prev.json, the before model of the delta
    board for a repo that does not track .architecture/. --render-only never calls this."""
    if os.path.exists(jpath):
        shutil.copyfile(jpath, os.path.join(os.path.dirname(jpath), "current.architecture.prev.json"))


# ---------------------------------------------------------------- main
def need_tools():
    """A full run shells out to the code-index tool and claude: say so up front instead of a FileNotFoundError traceback mid-run."""
    miss = [t for t in (INDEX_TOOL, "claude") if not shutil.which(t)]
    if miss:
        sys.exit("gen.py: required tool not found on PATH: " + ", ".join(miss) + ". A full run needs the code-graph tool (BREE_INDEX_TOOL, default code-index) and claude (LLM). Use --render-only to re-render an existing .architecture/current.architecture.json.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--flow", action="append", default=[], help='"name" or "name::entry_symbol" (repeatable)')
    ap.add_argument("--refresh", help="regenerate only this flow in the existing document")
    ap.add_argument("--runs", type=int, default=1, help="LLM runs per flow (stability); the first is drawn")
    ap.add_argument("--model", default="haiku")
    ap.add_argument("--max-tokens", type=int, default=100000, help="hard cap on LLM tokens (in+out) for this run")
    ap.add_argument("--render-only", action="store_true")
    ap.add_argument("--dry", action="store_true", help="walk + print the selection prompt size per flow (0 tokens), no LLM")
    ap.add_argument("--out", help="output dir (default ROOT/.architecture)")
    ap.add_argument("--lang", default=None, help="content language of the page (BCP 47, default en); stored in the document and set as <html lang>")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    out_dir = a.out or os.path.join(root, ".architecture")
    os.makedirs(out_dir, exist_ok=True)
    jpath = os.path.join(out_dir, "current.architecture.json")
    if a.render_only:
        if not os.path.exists(jpath):
            # No code-index model: render the agent boards alone (render_agent.py, Python stdlib only).
            import render_agent
            render_agent.render_root(root, a.lang)
            return
        doc = json.load(open(jpath))
        if a.lang:
            doc["lang"] = a.lang
            json.dump(doc, open(jpath, "w"), indent=1)
        write_html(doc, os.path.join(out_dir, "current.html"), root)
        return
    need_tools()
    sys.stderr.write(subprocess.run([INDEX_TOOL, "graph", "build", root], capture_output=True, text=True).stdout[-160:] + "\n")
    g = Graph(root)
    commit = subprocess.run(["git", "-C", root, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    logs = []
    cands = g.entry_candidates()
    reqs = [(f.split("::")[0], f.split("::")[1] if "::" in f else None) for f in (a.flow or DEFAULT_FLOWS)]
    if a.dry:
        for name, entry in reqs:
            nodes = g.walk(entry or name, None, lambda p, o, k, c=None: 0)
            print(f"{name}: {len(nodes)} nodes, caller={g.caller(nodes[0]['sym']) if nodes else None}")
            print(tree_text(g, nodes) if os.environ.get("TREE") else "", end="")
            print("prompt ~tokens", len(select_prompt(g, name, nodes, False)) // 4)
        return
    prev_lang = None
    if a.refresh:
        old = json.load(open(jpath))
        prev_lang = old.get("lang")
        roles, runs, boards = old["roles"], old["generation"]["runs"], old["flows"]
        reqs = [(a.refresh, next((e for n, e in reqs if n == a.refresh), None))]
        mode = "refresh"
    else:
        out, log = llm(overview_prompt(g), a.model, "overview")
        logs.append(log)
        roles = {k: v for k, v in (out or {}).get("modules", {}).items() if k in g.modules}
        boards, runs, mode = [], [], "full"
    for name, entry in reqs:
        res = build_flow(g, name, entry, a.runs, a.model, logs, a.max_tokens, cands)
        if not res:
            continue
        b = board_flow(name, res, a.model, cands)
        if mode == "refresh":
            boards = [b if x["id"] == b["id"] else x for x in boards]
        else:
            boards.append(b)
    runs.append({"at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "mode": mode, "flows": [n for n, _ in reqs],
                 "calls": logs, "tokens": used(logs), "cap": a.max_tokens})
    doc = make_doc(g, roles, boards, runs, commit)
    keep_prev(jpath)
    doc["lang"] = a.lang or prev_lang or "en"
    json.dump(doc, open(jpath, "w"), indent=1)
    write_html(doc, os.path.join(out_dir, "current.html"), root)
    print(json.dumps({"mode": mode, "tokens": used(logs), "calls": [{k: l.get(k) for k in ("board", "model", "tokens_in", "tokens_out", "steps_picked", "dropped", "reordered")} for l in logs]}))


if __name__ == "__main__":
    main()
