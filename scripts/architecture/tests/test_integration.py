"""Integration fixes: module name fallback, one root. Run from scripts/architecture: python3 -m unittest discover -s tests"""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import render
from draw import humanize


def mod(id_, label, path):
    return {"id": "mod:" + id_, "label": label, "board": "overview", "kind": "module", "role": "", "sources": [{"path": path, "line": 1}]}


class Names(unittest.TestCase):
    def test_humanize(self):
        self.assertEqual(humanize("hm/term.py"), "Term")
        self.assertEqual(humanize("src/job_runner.ts"), "Job runner")
        self.assertEqual(humanize("pkg/__init__.py"), "Pkg")

    def test_module_without_a_name_shows_the_file_stem(self):
        doc = {"repo": "r", "boards": [{"id": "overview", "kind": "overview", "title": "x"}], "edges": [],
               "nodes": [mod("hm_term_py", "hm_term_py", "hm/term.py"), mod("hm_cli_py", "CLI entrypoint", "hm/cli.py")],
               "overview_hidden": {"hubs": [], "counts": {}}}
        out = render.fix_labels(doc)
        self.assertEqual([x["label"] for x in out["nodes"]], ["Term", "CLI entrypoint"])
        self.assertEqual(doc["nodes"][0]["label"], "hm_term_py")   # the input is not edited

class Modules(unittest.TestCase):
    def test_no_overview_board_is_the_empty_state(self):
        from types import SimpleNamespace
        from views import modules
        b = modules.build(SimpleNamespace(doc={"repo": "r", "boards": [], "nodes": [], "edges": []}))
        self.assertIn("No modules found", b.svg)


if __name__ == "__main__":
    unittest.main()
