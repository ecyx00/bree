"""Runtime views: python3 -m unittest discover -s scripts/architecture/tests (from the repo root) or run this file."""
import os, re, sys, tempfile, unittest
from types import SimpleNamespace
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
from views import TokenBudget, sequence, data_flow, state  # noqa: E402


def step(i, order, actor="tool", mod="mod:a", anchor=None):
    sym = anchor or f"f{i}"
    return {"id": f"flow-x:{sym}", "label": f"Do {sym}", "board": "flow-x", "kind": "step", "module": mod, "order": order, "actor": actor,
            "anchor": f"m/{mod[4:]}.py:{sym}", "sources": [{"path": f"m/{mod[4:]}.py", "line": i, "label": sym}]}


def doc(steps):
    ids = sorted(steps, key=lambda s: s["order"])
    return {"repo": "r", "boards": [{"id": "flow-x", "title": "x flow", "kind": "flow"}],
            "nodes": steps + [{"id": m, "label": m, "kind": "module", "sources": [{"path": f"m/{m[4:]}.py"}]} for m in ("mod:a", "mod:b")],
            "edges": [{"id": f"e{k}", "from": a["id"], "to": b["id"], "board": "flow-x", "solid": True, "via": "call"} for k, (a, b) in enumerate(zip(ids, ids[1:]))]}


class Graph:
    def __init__(self, bodies):
        self.bodies = bodies
    def span(self, sym, path):
        return (1, len(self.bodies[sym].splitlines())) if sym in self.bodies else None
    def lines(self, path):
        return self._cur
    def callees(self, sym, path):
        return []


def ctx_for(d, bodies=None, root="/nonexistent"):
    g = Graph(bodies or {})
    g.lines = lambda path, g=g: g._all
    g._all = []
    c = SimpleNamespace(doc=d, root=root, names={}, about={}, budget=TokenBudget(), graph=g)
    return c


class Runtime(unittest.TestCase):
    def test_sequence_order_is_walk_order(self):
        steps = [step(1, 3, mod="mod:b"), step(2, 1), step(3, 4, mod="mod:b"), step(4, 2, mod="mod:b")]  # list order != walk order
        b = sequence.build(ctx_for(doc(steps)))[0]
        walk = [s["id"].split(":", 1)[1] for s in sorted(steps, key=lambda s: s["order"])]
        self.assertEqual([m["id"].split(":", 1)[1] for m in b.nodes], walk)
        self.assertEqual(re.findall(r'class="node" data-id="seq-x:([^"]+)"', b.svg), walk)
        ys = [float(y) for y in re.findall(r'<path class="ed"[^>]* d="M[\d.]+ ([\d.]+)', b.svg)]
        self.assertEqual(ys, sorted(ys))
        self.assertLessEqual(len(b.title), 12)

    def test_cite_gate_drops_fabricated_keeps_real(self):
        with tempfile.TemporaryDirectory() as r:
            os.makedirs(f"{r}/src")
            open(f"{r}/src/job.py", "w").write("class Job(Enum):\n    QUEUED = 1\n    RUNNING = 2\n    DONE = 3\n")
            m = [{"name": "Job", "about": "job lifecycle", "cite": "src/job.py:1", "states": [
                {"name": "QUEUED", "cite": "src/job.py:2"}, {"name": "RUNNING", "cite": "src/job.py:3"}, {"name": "DONE", "cite": "src/job.py:4"},
                {"name": "FAILED", "cite": "src/job.py:4"},          # line exists but does not contain it
                {"name": "PAUSED", "cite": "src/ghost.py:1"},        # file does not exist
                {"name": "ARCHIVED", "cite": "src/job.py:99"},       # line does not exist
                {"name": "EVIL", "cite": "../../etc/passwd:1"}],     # outside the repo
                "transitions": [{"from": "QUEUED", "to": "RUNNING", "event": "start", "cite": "src/job.py:3"},
                                {"from": "RUNNING", "to": "FAILED", "event": "boom", "cite": "src/job.py:4"}]}]
            kept, st = state.gate(r, m)
            self.assertEqual([s["name"] for s in kept[0]["states"]], ["QUEUED", "RUNNING", "DONE"])
            self.assertEqual([(t["from"], t["to"]) for t in kept[0]["transitions"]], [("QUEUED", "RUNNING")])
            self.assertEqual(st["dropped"], 5)
            m[0]["states"] = m[0]["states"][:2]  # only 2 grounded states: the machine is dropped
            self.assertEqual(state.gate(r, m)[0], [])

    def test_dataflow_write_only_with_evidence(self):
        steps = [step(1, 1), step(2, 2, actor="Index", anchor="rd"), step(3, 3, actor="Index", anchor="wr"), step(4, 4, actor="Files", anchor="fr")]
        bodies = {"rd": "def rd():\n    db.execute('SELECT * FROM t')", "wr": "def wr():\n    db.execute('INSERT INTO t VALUES (1)')",
                  "fr": "def fr():\n    return open(p).read()"}
        c = ctx_for(doc(steps), bodies)
        c.graph._all = []
        orig = data_flow.step_text
        data_flow.step_text = lambda ctx, s: bodies.get(s["anchor"].rsplit(":", 1)[1], "")
        try:
            b = data_flow.build(c)[0]
        finally:
            data_flow.step_text = orig
        acc = {n["sym"]: n["access"] for n in b.nodes}
        self.assertEqual(acc, {"f1": None, "rd": "READ", "wr": "WRITE", "fr": "READ"})
        self.assertEqual(b.svg.count("WRITE</text>"), 1)
        self.assertLessEqual(len(b.title), 12)

class FileGraph:
    """Tiny gen.Graph stand-in over in-memory files: files {path: source}, defs {sym: (path, first line, last line)}, calls {sym: [callee syms]}."""
    def __init__(self, files, defs, calls):
        self.files, self.defs, self.calls = files, defs, calls
    def lines(self, path):
        return self.files[path].splitlines()
    def span(self, sym, path):
        d = self.defs.get(sym)
        return (d[1], d[2]) if d and d[0] == path else None
    def callees(self, sym, path):
        return [(c, self.defs[c][0], self.defs[c][1], 0, "call", 0) for c in self.calls.get(sym, [])]


class WalkEvidence(unittest.TestCase):
    SRC = ("def f1():\n    return 1\n"                                   # 1-2
           "def f2():\n    log_it()\n"                                    # 3-4
           "def log_it():\n    deep()\n"                                   # 5-6
           "def deep():\n    open('x.log', 'a').write('hit')\n"          # 7-8
           "def f3():\n    return db.execute('SELECT 1')\n")             # 9-10

    def test_write_in_unpicked_callee_lands_on_nearest_picked_step(self):
        files = {"m/a.py": self.SRC}
        defs = {"f1": ("m/a.py", 1, 2), "f2": ("m/a.py", 3, 4), "log_it": ("m/a.py", 5, 6), "deep": ("m/a.py", 7, 8), "f3": ("m/a.py", 9, 10)}
        calls = {"f1": ["f2"], "f2": ["log_it"], "log_it": ["deep"]}
        steps = [step(1, 1), step(2, 2), step(3, 3, anchor="f3")]      # log_it and deep are NOT picked
        c = ctx_for(doc(steps))
        c.graph = FileGraph(files, defs, calls)
        b = data_flow.build(c)[0]
        by = {n["sym"]: n for n in b.nodes}
        self.assertIsNone(by["f1"]["access"])                          # f1 only reaches f2, and f2 is picked: f1 owns nothing
        self.assertEqual(by["f2"]["access"], "WRITE")                  # the append sits two callees below f2
        self.assertEqual(by["f2"]["lane"], "FS WRITE")
        self.assertIn("deep", by["f2"]["detail"])
        self.assertEqual(by["f3"]["access"], "READ")
        self.assertIn("1 of 3 steps write", b.notes[0])


if __name__ == "__main__":
    unittest.main()
