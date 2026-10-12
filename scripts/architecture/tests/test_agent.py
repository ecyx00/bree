"""Agent-authored diagrams: validate_agent.py and views/agent.py.  python3 -m unittest discover -s scripts/architecture/tests"""
import json, os, sys, tempfile, unittest
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import validate_agent as va  # noqa: E402
import views  # noqa: E402
from views import agent  # noqa: E402

SRC = "def alpha():\n    return 1\n\n\nclass Beta:\n    pass\n" + "\n" * 20 + "def far():\n    pass\n"


def svg(ids, extra=""):
    nodes = "".join(f'<g class="node" data-id="{i}"><rect x="0" y="0" width="10" height="10"/><text>{i}</text></g>' for i in ids)
    return f'<svg viewBox="0 0 100 100" width="100" height="100">{extra}{nodes}</svg>'


def node(i, code):
    return {"id": i, "name": i, "kind": "module", "summary": "s", "what": "w", "why": "y", "connects": [], "code": code}


class Repo(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.root = self.td.name
        os.makedirs(os.path.join(self.root, "pkg"))
        open(os.path.join(self.root, "pkg", "m.py"), "w").write(SRC)

    def tearDown(self):
        self.td.cleanup()

    def diagram(self, nodes, s=None):
        d = {"id": "d1", "title": "T", "type": "architecture", "section": "Big picture", "purpose": "p", "order": 1, "svg": "d1.svg", "nodes": nodes}
        return d, (svg([n["id"] for n in nodes]) if s is None else s)


class Anchors(Repo):
    def test_bad_anchor_is_removed_and_good_kept(self):
        good = {"path": "pkg/m.py", "line": 1, "symbol": "alpha"}
        bad_sym = {"path": "pkg/m.py", "line": 1, "symbol": "far"}      # far is 26 lines away
        bad_file = {"path": "pkg/nope.py", "line": 1, "symbol": "alpha"}
        bad_line = {"path": "pkg/m.py", "line": 999, "symbol": "alpha"}
        escape = {"path": "../../etc/passwd", "line": 1, "symbol": "root"}
        d, s = self.diagram([node("d1:a", [good, bad_sym, bad_file, bad_line, escape])])
        r = va.validate_diagram(self.root, d, s)
        n = r["diagram"]["nodes"][0]
        self.assertEqual(n["code"], [good])
        self.assertEqual(len(r["removed"]), 4)
        self.assertFalse(n.get("unverified"))

    def test_symbol_within_three_lines_passes(self):
        d, s = self.diagram([node("d1:a", [{"path": "pkg/m.py", "line": 3, "symbol": "alpha"}])])  # alpha is on line 1, 2 away
        self.assertEqual(len(va.validate_diagram(self.root, d, s)["diagram"]["nodes"][0]["code"]), 1)

    def test_node_without_anchor_is_unverified(self):
        d, s = self.diagram([node("d1:a", [{"path": "pkg/nope.py", "line": 1, "symbol": "x"}]), node("d1:b", [{"path": "pkg/m.py", "line": 5, "symbol": "Beta"}])])
        r = va.validate_diagram(self.root, d, s)
        self.assertTrue(r["diagram"]["nodes"][0]["unverified"])
        self.assertFalse(r["diagram"]["nodes"][1].get("unverified"))


class Rejects(Repo):
    def test_more_than_20_percent_unverified_rejects(self):
        ok = {"path": "pkg/m.py", "line": 1, "symbol": "alpha"}
        nodes = [node(f"d1:n{i}", [ok]) for i in range(4)] + [node("d1:u1", []), node("d1:u2", [])]   # 2 of 6 = 33%
        r = va.validate_diagram(self.root, *self.diagram(nodes))
        self.assertFalse(r["ok"])
        self.assertTrue(any("unverified" in e for e in r["errors"]))

    def test_exactly_20_percent_passes(self):
        ok = {"path": "pkg/m.py", "line": 1, "symbol": "alpha"}
        nodes = [node(f"d1:n{i}", [ok]) for i in range(4)] + [node("d1:u1", [])]
        self.assertTrue(va.validate_diagram(self.root, *self.diagram(nodes))["ok"])

    def test_svg_script_href_and_id_mismatch(self):
        ok = {"path": "pkg/m.py", "line": 1, "symbol": "alpha"}
        nodes = [node("d1:a", [ok])]
        cases = {
            "script": svg(["d1:a"], "<script>alert(1)</script>"),
            "onclick": svg(["d1:a"], '<rect onclick="x()" width="1" height="1"/>'),
            "external href": svg(["d1:a"], '<image href="https://evil.test/x.png"/>'),
            "xlink href": svg(["d1:a"], '<use xmlns:xlink="http://www.w3.org/1999/xlink" xlink:href="http://x/y#z"/>'),
            "foreignObject": svg(["d1:a"], "<foreignObject/>"),
            "css url": svg(["d1:a"], "<style>.a{fill:url(https://x/y)}</style>"),
            "id mismatch": svg(["d1:other"]),
            "missing node": svg([]),
            "not xml": "<svg><g></svg>",
        }
        for name, s in cases.items():
            with self.subTest(name):
                self.assertFalse(va.validate_diagram(self.root, *self.diagram(nodes, s))["ok"])
        self.assertTrue(va.validate_diagram(self.root, *self.diagram(nodes, svg(["d1:a"], '<use href="#x"/>')))["ok"])


class Boards(Repo):
    def write(self, manifest):
        ad = os.path.join(self.root, ".architecture", "agent")
        os.makedirs(ad)
        json.dump(manifest, open(os.path.join(ad, "manifest.json"), "w"))
        for d in manifest:
            open(os.path.join(ad, d["svg"]), "w").write(svg([n["id"] for n in d["nodes"]]))

    def mk(self, i, order, section):
        d = {"id": f"d{i}", "title": f"T{i}", "type": "architecture", "section": section, "purpose": "p", "order": order, "svg": f"d{i}.svg",
             "nodes": [node(f"d{i}:a", [{"path": "pkg/m.py", "line": 1, "symbol": "alpha"}])]}
        d["nodes"][0]["connects"] = [{"to": "d%d:b" % i, "label": "calls", "dir": "out"}]
        return d

    def test_no_agent_dir_gives_no_boards_and_default_groups(self):
        ctx = views.Ctx({"repo": "r", "nodes": [], "edges": [], "boards": []}, self.root)
        self.assertEqual(agent.build(ctx), [])
        self.assertEqual(views.collect(ctx, ["agent"]), [])

    def test_manifest_order_and_facts_section(self):
        self.write([self.mk(1, 2, "Flows"), self.mk(2, 1, "Big picture"), self.mk(3, 3, "Flows")])
        ctx = views.Ctx({"repo": "r", "nodes": [], "edges": [], "boards": []}, self.root)
        boards = agent.build(ctx)
        self.assertEqual([b.id for b in boards], ["d2", "d1", "d3"])
        self.assertEqual([b.group for b in boards], ["Big picture", "Flows", "Flows"])
        n = boards[0].nodes[0]
        self.assertEqual((n["id"], n["kind"], n["anchor"]), ("d2:a", "module", "pkg/m.py#alpha"))
        for k in ("summary", "what", "why", "connects", "code"):
            self.assertIn(k, n)
        # collect: agent boards first in manifest order, a deterministic board moves to the last section "Facts"
        fake = types_module(self.root)
        got = views.collect(views.Ctx({"repo": "r", "nodes": [], "edges": [], "boards": []}, self.root), ["fakefact", "agent"])
        self.assertEqual([b.id for b in got], ["d2", "d1", "d3", "factboard"])
        self.assertEqual(got[-1].group, "Facts")
        self.assertEqual(views.GROUPS, ["Big picture", "Flows", "Facts"])
        del fake
        views.collect(ctx, ["fakefact"])    # without agent output the nav is today's again
        self.assertEqual(views.GROUPS, views.BASE_GROUPS)


def types_module(root):
    """Register a throw-away deterministic view called views.fakefact."""
    import types
    m = types.ModuleType("views.fakefact")
    m.build = lambda ctx: views.Board(id="factboard", group="Components", title="F", purpose="p", svg=views.empty_svg("x"))
    sys.modules["views.fakefact"] = m
    return m


if __name__ == "__main__":
    unittest.main()
