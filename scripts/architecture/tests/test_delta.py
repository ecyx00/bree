"""Stage 2: the delta board and the before-model source. Run: python3 -m unittest discover -s tests   (from scripts/architecture)"""
import copy, hashlib, json, os, re, subprocess, sys, tempfile, unittest
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import gen
from views import delta, TokenBudget


def mod(i, label, path=None, role=""):
    return {"id": "mod:" + i, "label": label, "board": "overview", "kind": "module", "role": role, "sources": [{"path": path or f"hm/{i}.py", "line": 1}]}


def edge(eid, a, b, solid=True):
    return {"id": eid, "from": "mod:" + a, "to": "mod:" + b, "board": "overview", "solid": solid, "weight": 1}


def doc(mods, edges, commit="aaa1111"):
    return {"schema": "bree-architecture/2", "repo": "r", "commit": commit, "generated_at": "2026-10-09T10:00:00+02:00",
            "boards": [{"id": "overview", "kind": "overview", "title": "Modules"}], "nodes": mods, "edges": edges, "flows": [], "roles": {},
            "overview_hidden": {"hubs": [], "counts": {}}, "generation": {"runs": [], "totals": {}}}


# Layers (0 = top). Before: a0 b1 c2 d2 x1.  After: a0 b1 c2 x2 g1.  So x moves from layer 1 to 2.
BEFORE = doc([mod("a", "A"), mod("b", "B"), mod("c", "C"), mod("d", "D"), mod("x", "X")],
             [edge("r1", "a", "b"), edge("r2", "b", "c"), edge("r3", "a", "c"), edge("r4", "x", "d")])
AFTER = doc([mod("a", "A"), mod("b", "B renamed"), mod("c", "C"), mod("x", "X"), mod("g", "G")],
            [edge("r1", "a", "b"), edge("r2", "b", "c"), edge("r3", "a", "x"), edge("r5", "g", "c")], commit="bbb2222")


def pairs(changes):
    return {(c["change"], c["target"]) for c in changes}


class Kinds(unittest.TestCase):
    def test_five_change_kinds(self):
        got = pairs(delta.compare(BEFORE, AFTER))
        self.assertEqual(got, {("ADDED", "mod:g"), ("REMOVED", "mod:d"), ("CHANGED", "mod:b"), ("MOVED", "mod:x"), ("REWIRED", "r3")})

    def test_identical_models_have_no_changes(self):
        self.assertEqual(delta.compare(BEFORE, copy.deepcopy(BEFORE)), [])

    def test_changed_and_moved_is_two_entries(self):
        a = copy.deepcopy(AFTER)
        a["nodes"][3]["label"] = "X2"
        self.assertTrue({("CHANGED", "mod:x"), ("MOVED", "mod:x")} <= pairs(delta.compare(BEFORE, a)))

    def test_rewire_text_names_both_ends(self):
        txt = next(c["text"] for c in delta.compare(BEFORE, AFTER) if c["change"] == "REWIRED")
        self.assertIn("A → C", txt)
        self.assertIn("A → X", txt)


def ctx_for(d, root, arch_dir):
    return SimpleNamespace(doc=d, root=root, arch_dir=arch_dir, budget=TokenBudget(cap=0), names={}, about={})


def write(path, d):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(d, open(path, "w"))


class Board(unittest.TestCase):
    def render(self, before, after):
        td = tempfile.mkdtemp()
        a = os.path.join(td, ".architecture")
        if before is not None:
            write(os.path.join(a, "current.architecture.prev.json"), before)
        write(os.path.join(a, "current.architecture.json"), after)
        return delta.build(ctx_for(after, td, a))

    def test_full_board_has_three_panels_and_an_exact_ledger(self):
        b = self.render(BEFORE, AFTER)
        self.assertEqual(b.group, "Changes")
        self.assertEqual(b.tokens, 0)
        self.assertIn('data-diagram="architecture-delta"', b.svg)
        self.assertEqual(len(re.findall(r'data-snapshot-frame="(?:before|after)"', b.svg)), 2)
        self.assertTrue(re.search(r'data-snapshot="before"', b.svg) and re.search(r'data-snapshot="after"', b.svg))
        led = re.findall(r'data-change="(\w+)" data-target="([^"]+)"', b.svg)
        self.assertEqual(set(led), pairs(delta.compare(BEFORE, AFTER)))
        self.assertEqual(len(led), len(set(led)))
        self.assertTrue(re.search(r'data-before-fp="prev:[0-9a-f]{16}"', b.svg))
        self.assertTrue(all(nd["id"].startswith("delta:") for nd in b.nodes))

    def test_attribute_only_change_is_a_ledger_table(self):
        after = copy.deepcopy(BEFORE)
        after["nodes"][1]["label"] = "B renamed"
        after["nodes"][2]["role"] = "does things"
        b = self.render(BEFORE, after)
        self.assertNotIn("data-diagram", b.svg)
        self.assertNotIn("data-snapshot", b.svg)
        self.assertEqual(set(re.findall(r'data-change="(\w+)" data-target="([^"]+)"', b.svg)), {("CHANGED", "mod:b"), ("CHANGED", "mod:c")})

    def test_no_before_model_is_the_empty_state(self):
        b = self.render(None, AFTER)
        self.assertIn("No earlier version to compare with", b.svg)
        self.assertIn('data-before-fp="none"', b.svg)
        self.assertEqual(b.nodes, [])

    def test_nothing_changed_says_so(self):
        b = self.render(AFTER, AFTER)
        self.assertIn("No changes since the previous generation", b.svg)

    def test_over_budget_keeps_at_most_8_ledger_entries(self):
        after = copy.deepcopy(BEFORE)
        after["nodes"] += [mod(f"n{i}", f"N{i}") for i in range(12)]
        b = self.render(BEFORE, after)
        self.assertLessEqual(len(re.findall(r"data-change=", b.svg)), 8)
        self.assertIn("more", b.svg)


def git(root, *a):
    return subprocess.run(["git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t", *a], capture_output=True, text=True, check=True).stdout.strip()


class Source(unittest.TestCase):
    def test_git_head_wins_when_the_file_is_tracked(self):
        td = tempfile.mkdtemp()
        a = os.path.join(td, ".architecture")
        git(td, "init", "-q")
        write(os.path.join(a, "current.architecture.json"), BEFORE)
        git(td, "add", ".architecture/current.architecture.json")
        git(td, "commit", "-q", "-m", "x")
        write(os.path.join(a, "current.architecture.json"), AFTER)
        write(os.path.join(a, "current.architecture.prev.json"), doc([], []))   # must be ignored
        src = delta.before_source(td, a)
        self.assertEqual(src["kind"], "git")
        self.assertEqual(src["doc"]["commit"], "aaa1111")
        self.assertRegex(src["fp"], r"^git:[0-9a-f]{40}:[0-9a-f]{40}$")

    def test_untracked_falls_back_to_the_prev_file(self):
        td = tempfile.mkdtemp()
        a = os.path.join(td, ".architecture")
        git(td, "init", "-q")
        write(os.path.join(a, "current.architecture.json"), AFTER)
        write(os.path.join(a, "current.architecture.prev.json"), BEFORE)
        src = delta.before_source(td, a)
        self.assertEqual(src["kind"], "prev")
        self.assertEqual(src["doc"]["commit"], "aaa1111")
        raw = open(os.path.join(a, "current.architecture.prev.json"), "rb").read()
        self.assertEqual(src["fp"], "prev:" + hashlib.sha256(raw).hexdigest()[:16])

    def test_no_git_no_prev_is_none(self):
        td = tempfile.mkdtemp()
        write(os.path.join(td, ".architecture", "current.architecture.json"), AFTER)
        self.assertIsNone(delta.before_source(td, os.path.join(td, ".architecture")))

    def test_prev_fingerprint_matches_the_swift_test_vector(self):
        self.assertEqual(delta.prev_fingerprint(b"abc"), "prev:ba7816bf8f01cfea")


class KeepPrev(unittest.TestCase):
    def run_main(self, argv, d):
        a = os.path.join(d, ".architecture")
        stub_graph = mock.MagicMock()
        stub_graph.entry_candidates.return_value = []
        with mock.patch.object(sys, "argv", ["gen.py", d, *argv]), mock.patch.object(gen, "Graph", return_value=stub_graph), \
                mock.patch.object(gen, "need_tools"), \
                mock.patch.object(gen.subprocess, "run", return_value=SimpleNamespace(stdout="", stderr="", returncode=0)), \
                mock.patch.object(gen, "build_flow", return_value=None), mock.patch.object(gen, "make_doc", return_value={"repo": "new"}), \
                mock.patch.object(gen, "llm", return_value=({}, {})), mock.patch.object(gen, "write_html"):
            gen.main()
        return a

    def fixture(self):
        d = tempfile.mkdtemp()
        old = {"repo": "old", "roles": {}, "flows": [], "generation": {"runs": []}}
        write(os.path.join(d, ".architecture", "current.architecture.json"), old)
        return d

    def test_refresh_keeps_the_old_json_as_prev(self):
        d = self.fixture()
        a = self.run_main(["--refresh", "x"], d)
        self.assertEqual(json.load(open(os.path.join(a, "current.architecture.prev.json")))["repo"], "old")
        self.assertEqual(json.load(open(os.path.join(a, "current.architecture.json")))["repo"], "new")

    def test_full_run_keeps_the_old_json_as_prev(self):
        d = self.fixture()
        a = self.run_main([], d)
        self.assertEqual(json.load(open(os.path.join(a, "current.architecture.prev.json")))["repo"], "old")

    def test_render_only_never_writes_prev(self):
        d = self.fixture()
        a = self.run_main(["--render-only"], d)
        self.assertFalse(os.path.exists(os.path.join(a, "current.architecture.prev.json")))


if __name__ == "__main__":
    unittest.main()
